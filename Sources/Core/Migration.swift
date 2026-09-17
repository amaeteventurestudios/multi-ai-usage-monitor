import Foundation

/// Preferences written by the upstream-derived build this project grew out of.
/// Read once, from that build's own defaults domain, so an existing
/// installation keeps working after the bundle identifier changes.
struct LegacySettingsSnapshot: Equatable {
    var anthropicEnabled: Bool = true
    var openAIEnabled: Bool = true
    var anthropicPath: String?
    var openAIPath: String?
    var refreshIntervalMinutes: Int?
    var alertThresholdPercent: Int?

    /// nil when there is nothing to migrate.
    static func read(from defaults: UserDefaults?) -> LegacySettingsSnapshot? {
        guard let d = defaults else { return nil }
        let keys = ["provider.anthropic.enabled", "provider.openai.enabled",
                    "provider.anthropic.path", "provider.openai.path",
                    "refreshIntervalMinutes", "alertThresholdPercent"]
        guard keys.contains(where: { d.object(forKey: $0) != nil }) else { return nil }

        var s = LegacySettingsSnapshot()
        if d.object(forKey: "provider.anthropic.enabled") != nil {
            s.anthropicEnabled = d.bool(forKey: "provider.anthropic.enabled")
        }
        if d.object(forKey: "provider.openai.enabled") != nil {
            s.openAIEnabled = d.bool(forKey: "provider.openai.enabled")
        }
        s.anthropicPath = (d.string(forKey: "provider.anthropic.path")).flatMap { $0.isEmpty ? nil : $0 }
        s.openAIPath = (d.string(forKey: "provider.openai.path")).flatMap { $0.isEmpty ? nil : $0 }
        let interval = d.integer(forKey: "refreshIntervalMinutes")
        s.refreshIntervalMinutes = interval > 0 ? interval : nil
        let threshold = d.integer(forKey: "alertThresholdPercent")
        s.alertThresholdPercent = threshold > 0 ? threshold : nil
        return s
    }
}

/// What the app found on this Mac when it first looked. Passed in rather than
/// probed inside the migration so the logic is testable without credentials.
struct DetectedCredentials {
    var claudeCodeKeychain: Bool
    var codexDefault: Bool
}

/// Turns "one provider, one credential" into "accounts".
///
/// Deliberately conservative: it creates an account for each credential this
/// Mac actually has, carries across the provider on/off switches and custom
/// paths, and sets no reset override at all. Both providers report their own
/// reset timestamps, so baking a weekday and hour into everyone's migrated
/// configuration would be inventing a fact. Per-account reset rules are there
/// for people whose provider stays silent — set in the account editor, not here.
///
/// It also gives the accounts no name and no identity. Naming happens once the
/// provider has been asked who the credential belongs to, which the coordinator
/// does on first launch — so a migrated account ends up called
/// "Claude (you@example.com)" rather than carrying a counter forever.
enum LegacyMigration {

    static func accounts(legacy: LegacySettingsSnapshot?,
                         detected: DetectedCredentials) -> [AIAccount] {
        var out: [AIAccount] = []

        // Claude: a custom path from the old settings wins, else the Claude Code
        // Keychain item, but only if something is actually there.
        let claudeSource: CredentialSource? = {
            if let p = legacy?.anthropicPath { return .file(path: p) }
            return detected.claudeCodeKeychain ? .claudeCodeKeychain : nil
        }()
        if let source = claudeSource {
            out.append(AIAccount(provider: .claude,
                                 enabled: legacy?.anthropicEnabled ?? true,
                                 order: out.count,
                                 credentialSource: source))
        }

        let openAISource: CredentialSource? = {
            if let p = legacy?.openAIPath { return .file(path: p) }
            return detected.codexDefault ? .codexDefault : nil
        }()
        if let source = openAISource {
            out.append(AIAccount(provider: .openAI,
                                 enabled: legacy?.openAIEnabled ?? true,
                                 order: out.count,
                                 credentialSource: source))
        }
        return out
    }

    /// Carry across the two global preferences the old build had.
    static func apply(legacy: LegacySettingsSnapshot?, to settings: AppSettings) {
        guard let legacy = legacy else { return }
        if let m = legacy.refreshIntervalMinutes { settings.refreshIntervalMinutes = m }
        if let t = legacy.alertThresholdPercent { settings.warningThresholdPercent = t }
    }
}
