// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Venture Studios. See NOTICE.

import Foundation

/// The subset of ~/.codex/auth.json we need. Deliberately a subset: the file is
/// read field by field and never copied wholesale into memory dumps or logs.
struct CodexAuth: Equatable {
    let accessToken: String
    let accountId: String?
    let expiresAt: Date?

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
        guard let path = path(for: source),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> CodexAuth? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        return CodexAuth(accessToken: access,
                         accountId: tokens["account_id"] as? String,
                         expiresAt: jwtExpiry(access))
    }

    /// Non-secret metadata for the settings pane: the plan and e-mail recorded
    /// on the credential, when present. Used to suggest a display name for a
    /// newly added account so the user does not have to invent one.
    static func identityHint(source: CredentialSource) -> (email: String?, plan: String?) {
        guard let path = path(for: source),
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = jwtClaims(idToken) else { return (nil, nil) }
        let email = claims["email"] as? String
        var plan: String?
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            plan = auth["chatgpt_plan_type"] as? String
        }
        return (email, plan)
    }

    static func status(of source: CredentialSource) -> CredentialStatus {
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
