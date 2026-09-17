// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Umanah. See NOTICE.

import Foundation

/// The OAuth material Claude Code stores. Decoded from the `claudeAiOauth`
/// wrapper both the Keychain item and an exported JSON file use.
struct ClaudeCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?        // epoch milliseconds
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?

    var isExpired: Bool {
        guard let e = expiresAt else { return false }
        return Date().timeIntervalSince1970 * 1000 >= (e - 60_000) // 60s slack
    }

    /// Parse the wrapper shape, which is what both storage locations contain.
    static func parse(json: String) -> ClaudeCredentials? {
        guard let data = json.data(using: .utf8) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> ClaudeCredentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Accept either the wrapper or a bare credential object, so a user
        // pasting an exported blob does not have to know which shape they have.
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let credData = try? JSONSerialization.data(withJSONObject: oauth),
              let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: credData),
              !creds.accessToken.isEmpty else { return nil }
        return creds
    }

    /// Re-encode in Claude Code's wrapper shape, so a credential we write back
    /// stays readable by the tool that owns it.
    func serialized() -> String? {
        var oauth: [String: Any] = ["accessToken": accessToken]
        if let r = refreshToken { oauth["refreshToken"] = r }
        if let e = expiresAt { oauth["expiresAt"] = e }
        if let s = scopes { oauth["scopes"] = s }
        if let s = subscriptionType { oauth["subscriptionType"] = s }
        if let t = rateLimitTier { oauth["rateLimitTier"] = t }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Reads and writes Claude credentials for one account, according to that
/// account's configured source.
///
/// Three sources, three write policies:
///   * Claude Code's Keychain item — refreshed tokens are written back, which is
///     what keeps Claude Code itself working (it expects whoever refreshes the
///     token to store it).
///   * This app's own Keychain item — ours entirely, written freely.
///   * A file the user pointed at — never written. We hold the refreshed token
///     in memory for the session instead of editing a file we do not own.
enum ClaudeCredentialStore {
    static let keychainService = "Claude Code-credentials"
    static var keychainAccount: String { NSUserName() }

    static func read(source: CredentialSource) -> ClaudeCredentials? {
        switch source {
        case .claudeCodeKeychain:
            guard let json = Keychain.read(service: keychainService, account: keychainAccount) else { return nil }
            return ClaudeCredentials.parse(json: json)
        case .appKeychain(let id):
            guard let json = Keychain.read(service: AppInfo.appKeychainService, account: id) else { return nil }
            return ClaudeCredentials.parse(json: json)
        case .file(let path):
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return ClaudeCredentials.parse(data: data)
        case .codexDefault:
            return nil // not a Claude source
        }
    }

    /// True when the write actually persisted somewhere. File sources return
    /// false by design: a refreshed token stays in memory for this session.
    @discardableResult
    static func write(_ creds: ClaudeCredentials, to source: CredentialSource) -> Bool {
        guard let json = creds.serialized() else { return false }
        switch source {
        case .claudeCodeKeychain:
            return Keychain.write(service: keychainService, account: keychainAccount,
                                  value: json, label: keychainService)
        case .appKeychain(let id):
            return Keychain.write(service: AppInfo.appKeychainService, account: id,
                                  value: json, label: "\(AppInfo.name) credential")
        case .file, .codexDefault:
            Diagnostics.shared.debug("refreshed Claude token held in memory; file sources are never written")
            return false
        }
    }

    /// Store a credential the user imported, under this app's own service.
    @discardableResult
    static func importCredential(_ json: String, forAccountID id: UUID) -> Bool {
        guard let creds = ClaudeCredentials.parse(json: json), let normalized = creds.serialized() else {
            return false
        }
        return Keychain.write(service: AppInfo.appKeychainService, account: id.uuidString,
                              value: normalized, label: "\(AppInfo.name) credential")
    }

    /// Remove only a copy this app owns. Never touches Claude Code's item.
    @discardableResult
    static func deleteImportedCredential(forAccountID id: UUID) -> Bool {
        Keychain.delete(service: AppInfo.appKeychainService, account: id.uuidString)
    }

    static func status(of source: CredentialSource) -> CredentialStatus {
        switch source {
        case .file(let path):
            guard FileManager.default.fileExists(atPath: path) else { return .missing }
            guard FileManager.default.isReadableFile(atPath: path) else { return .unreadable }
            guard let creds = read(source: source) else { return .invalid }
            return creds.isExpired ? .expired : .detected
        case .claudeCodeKeychain, .appKeychain:
            guard let creds = read(source: source) else { return .missing }
            return creds.isExpired ? .expired : .detected
        case .codexDefault:
            return .invalid
        }
    }
}
