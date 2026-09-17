// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Umanah. See NOTICE.

import Foundation

/// The subset of ~/.codex/auth.json we need. Deliberately a subset: the file is
/// read field by field and never copied wholesale into memory dumps or logs.
struct CodexAuth: Equatable {
    let accessToken: String
    let accountId: String?
    let expiresAt: Date?
    /// Identity claims read out of the id token, when one is present.
    var email: String?
    var planRaw: String?

    var isExpired: Bool {
        guard let e = expiresAt else { return false }   // unknown expiry: try anyway
        return Date() >= e.addingTimeInterval(-60)      // 60s slack
    }
}

/// Reads Codex/ChatGPT credentials. Read-only, always.
///
/// The Codex CLI and the ChatGPT desktop app own the refresh cycle for this
/// file. A botched write here would sign the user out of Codex entirely, so an
/// expired token is reported rather than renewed — opening ChatGPT or running
/// `codex` refreshes it and the next poll picks it up.
enum CodexCredentialStore {
    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    }

    static func path(for source: CredentialSource) -> String? {
        switch source {
        case .codexDefault: return defaultPath
        case .file(let p): return p
        default: return nil
        }
    }

    static func read(source: CredentialSource) -> CodexAuth? {
        guard let data = rawCredential(source: source) else { return nil }
        return parse(data: data)
    }

    /// The credential document itself, from wherever this account keeps it: a
    /// file another tool owns, or a copy imported into this app's Keychain
    /// entry. Kept private to this type — callers get parsed fields, never the
    /// raw document.
    static func rawCredential(source: CredentialSource) -> Data? {
        switch source {
        case .codexDefault, .file:
            guard let path = path(for: source) else { return nil }
            return FileManager.default.contents(atPath: path)
        case .appKeychain(let id):
            return Keychain.read(service: AppInfo.appKeychainService, account: id)
                .map { Data($0.utf8) }
        case .claudeCodeKeychain:
            return nil
        }
    }

    static func parse(data: Data) -> CodexAuth? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        var auth = CodexAuth(accessToken: access,
                             accountId: tokens["account_id"] as? String,
                             expiresAt: jwtExpiry(access))
        if let idToken = tokens["id_token"] as? String, let claims = jwtClaims(idToken) {
            auth.email = claims["email"] as? String
            if let openAIAuth = claims["https://api.openai.com/auth"] as? [String: Any] {
                auth.planRaw = openAIAuth["chatgpt_plan_type"] as? String
            }
        }
        return auth
    }

    /// Non-secret metadata for the settings pane: the plan and e-mail recorded
    /// on the credential, when present. Used to suggest a display name for a
    /// newly added account so the user does not have to invent one.
    static func identityHint(source: CredentialSource) -> (email: String?, plan: String?) {
        guard let auth = read(source: source) else { return (nil, nil) }
        return (auth.email, auth.planRaw)
    }

    /// Store a copy of a credential document under this app's own Keychain
    /// service, so the account no longer depends on whichever account Codex is
    /// currently signed in to.
    @discardableResult
    static func capture(from source: CredentialSource, forAccountID id: UUID) -> Bool {
        guard let data = rawCredential(source: source),
              parse(data: data) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              // Re-serialised compactly: a pretty-printed document would come
              // back from `security` hex-encoded, and there is no reason to
              // store the newlines.
              let compact = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: compact, encoding: .utf8) else { return false }
        return Keychain.write(service: AppInfo.appKeychainService, account: id.uuidString,
                              value: text, label: "\(AppInfo.name) credential")
    }

    static func status(of source: CredentialSource) -> CredentialStatus {
        if case .appKeychain = source {
            guard let auth = read(source: source) else { return .missing }
            return auth.isExpired ? .expired : .detected
        }
        guard let path = path(for: source) else { return .invalid }
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard FileManager.default.isReadableFile(atPath: path) else { return .unreadable }
        guard let auth = read(source: source) else { return .invalid }
        return auth.isExpired ? .expired : .detected
    }

    /// Validate a path the user picked, without disclosing the contents.
    static func validate(path: String) -> Result<Void, AccountError> {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(AccountError(kind: .invalidPath, message: "No file at that path."))
        }
        guard FileManager.default.isReadableFile(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            return .failure(AccountError(kind: .invalidPath, message: "That file is not readable."))
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return .failure(AccountError(kind: .invalidPath, message: "That file is not valid JSON."))
        }
        guard parse(data: data) != nil else {
            return .failure(AccountError(kind: .invalidPath,
                                         message: "That JSON has no tokens.access_token field."))
        }
        return .success(())
    }
}

/// Read a JWT payload *without* verifying the signature. We only need to know
/// whether a call is worth making and which plan to label an account with; the
/// server remains the real authority.
func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func jwtExpiry(_ token: String) -> Date? {
    guard let claims = jwtClaims(token),
          let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
    return Date(timeIntervalSince1970: exp)
}
