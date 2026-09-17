import Foundation

/// What the menu bar title is *about*: every account, one figure per provider,
/// or nothing but a marker.
///
/// Deliberately separate from `PerAccountFormat`, which decides how wide each
/// account's label is. The two used to be tangled together under one set of
/// names that included two different things called "Minimal".
enum MenuBarSummaryMode: String, CaseIterable, Codable {
    /// Every enabled account, laid out according to `PerAccountFormat`.
    case perAccount
    /// The highest usage for each provider: "Claude 43% · OpenAI 88%".
    case provider
    /// Just a marker: "AI".
    case iconOnly

    var displayName: String {
        switch self {
        case .perAccount: return "Per Account — show every account"
        case .provider:   return "Provider — highest usage per provider"
        case .iconOnly:   return "Icon Only — just “AI”"
        }
    }

    var explanation: String {
        switch self {
        case .perAccount:
            return "One label per enabled account, in the order you arranged them. "
                 + "Choose how wide those labels are below."
        case .provider:
            return "Shows the highest current usage for each provider, "
                 + "e.g. “Claude 43% · OpenAI 88%”."
        case .iconOnly:
            return "Just “AI”, with an exclamation mark if an account needs attention."
        }
    }

    /// Preferences written before these modes were separated.
    static func migrating(from raw: String) -> MenuBarSummaryMode? {
        switch raw {
        case "compact": return .perAccount
        case "minimal": return .iconOnly
        default: return MenuBarSummaryMode(rawValue: raw)
        }
    }
}

/// How wide each account's menu bar label is, when the summary mode is
/// per-account.
///
/// The right answer depends on the screen, the notch and how many other status
/// items are up there, none of which the app can judge for somebody — so this
/// is a choice, not an automatic guess.
enum PerAccountFormat: String, CaseIterable, Codable {
    /// "C Amaete 57% · C StarLogic 22%"
    case detailed
    /// "C-A 57% · C-S 22%"
    case compact
    /// "A 57% · S 22%"
    case minimalLabels

    var displayName: String {
        switch self {
        case .detailed:      return "Detailed"
        case .compact:       return "Compact"
        case .minimalLabels: return "Minimal Labels"
        }
    }

    var explanation: String {
        switch self {
        case .detailed:
            return "Shows provider and account names. Best for large displays."
        case .compact:
            return "Uses provider and account abbreviations to save space."
        case .minimalLabels:
            return "Shows only short account labels and usage. Best for laptops."
        }
    }
}

/// Non-secret preferences, persisted in user defaults under a versioned schema.
///
/// Instance-based rather than a global enum so tests can point it at a scratch
/// defaults suite instead of the real one.
final class AppSettings {
    static let currentSchemaVersion = 1

    /// How solid the app's own windows are drawn, as a fraction.
    ///
    /// 1.0 is a completely solid window — in Dark Mode, a properly dark panel;
    /// lower values let the desktop show through and lighten it. The floor is
    /// deliberately high: below about 0.7 the text starts competing with
    /// whatever is behind it, and a preference that can make the app unreadable
    /// is not a preference worth offering.
    static let minimumBackgroundOpacity = 0.70
    static let maximumBackgroundOpacity = 1.00
    static let defaultBackgroundOpacity = 0.95

    static func clampBackgroundOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBackgroundOpacity }
        return min(maximumBackgroundOpacity, max(minimumBackgroundOpacity, value))
    }

    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        registerDefaults()
    }

    private enum Key {
        static let schemaVersion = "settingsSchemaVersion"
        static let refreshMinutes = "refresh.intervalMinutes"   // 0 == manual only
        static let summaryMode = "display.summaryMode"
        static let showPercentages = "display.showPercentages"
        static let showCountdown = "display.showResetCountdown"
        static let onlyHighest = "display.onlyHighestInMenuBar"
        static let perAccountFormat = "display.perAccountFormat"
        static let backgroundOpacity = "display.backgroundOpacity"
        static let usageWarnings = "notifications.usageWarningsEnabled"
        static let warningThreshold = "notifications.warningThresholdPercent"
        static let authWarnings = "notifications.authWarningsEnabled"
        static let debugLogging = "advanced.debugLogging"
        static let includeIdentities = "advanced.diagnosticsIncludeIdentities"
        static let migrated = "migration.legacyImported"
    }

    private func registerDefaults() {
        d.register(defaults: [
            Key.refreshMinutes: 5,
            Key.summaryMode: MenuBarSummaryMode.perAccount.rawValue,
            Key.perAccountFormat: PerAccountFormat.detailed.rawValue,
            Key.showPercentages: true,
            Key.showCountdown: true,
            Key.onlyHighest: false,
            Key.backgroundOpacity: AppSettings.defaultBackgroundOpacity,
            Key.usageWarnings: true,
            Key.warningThreshold: 90,
            Key.authWarnings: true,
            Key.debugLogging: false,
            Key.includeIdentities: false,
        ])
    }

    var schemaVersion: Int {
        get { d.integer(forKey: Key.schemaVersion) }
        set { d.set(newValue, forKey: Key.schemaVersion) }
    }

    /// nil means "manual refresh only".
    var refreshIntervalMinutes: Int? {
        get {
            let v = d.integer(forKey: Key.refreshMinutes)
            return v <= 0 ? nil : min(120, v)
        }
        set { d.set(newValue.map { min(120, max(1, $0)) } ?? 0, forKey: Key.refreshMinutes) }
    }

    var refreshInterval: TimeInterval? { refreshIntervalMinutes.map { TimeInterval($0 * 60) } }

    var menuBarSummaryMode: MenuBarSummaryMode {
        get { MenuBarSummaryMode.migrating(from: d.string(forKey: Key.summaryMode) ?? "")
                ?? .perAccount }
        set { d.set(newValue.rawValue, forKey: Key.summaryMode) }
    }

    var perAccountFormat: PerAccountFormat {
        get { PerAccountFormat(rawValue: d.string(forKey: Key.perAccountFormat) ?? "") ?? .detailed }
        set { d.set(newValue.rawValue, forKey: Key.perAccountFormat) }
    }

    var showPercentages: Bool {
        get { d.bool(forKey: Key.showPercentages) }
        set { d.set(newValue, forKey: Key.showPercentages) }
    }
    var showResetCountdown: Bool {
        get { d.bool(forKey: Key.showCountdown) }
        set { d.set(newValue, forKey: Key.showCountdown) }
    }
    var onlyHighestInMenuBar: Bool {
        get { d.bool(forKey: Key.onlyHighest) }
        set { d.set(newValue, forKey: Key.onlyHighest) }
    }

    /// Clamped on the way in *and* on the way out, so neither a mistyped
    /// defaults write nor a value from a future version with a wider range can
    /// render the app unreadable.
    var backgroundOpacity: Double {
        get { AppSettings.clampBackgroundOpacity(d.double(forKey: Key.backgroundOpacity)) }
        set { d.set(AppSettings.clampBackgroundOpacity(newValue), forKey: Key.backgroundOpacity) }
    }

    var usageWarningsEnabled: Bool {
        get { d.bool(forKey: Key.usageWarnings) }
        set { d.set(newValue, forKey: Key.usageWarnings) }
    }
    var warningThresholdPercent: Int {
        get { min(100, max(1, d.integer(forKey: Key.warningThreshold) == 0 ? 90 : d.integer(forKey: Key.warningThreshold))) }
        set { d.set(min(100, max(1, newValue)), forKey: Key.warningThreshold) }
    }
    var authWarningsEnabled: Bool {
        get { d.bool(forKey: Key.authWarnings) }
        set { d.set(newValue, forKey: Key.authWarnings) }
    }

    var debugLogging: Bool {
        get { d.bool(forKey: Key.debugLogging) }
        set {
            d.set(newValue, forKey: Key.debugLogging)
            Diagnostics.shared.minimumLevel = newValue ? .debug : .info
        }
    }

    var diagnosticsIncludeIdentities: Bool {
        get { d.bool(forKey: Key.includeIdentities) }
        set { d.set(newValue, forKey: Key.includeIdentities) }
    }

    var legacyMigrationDone: Bool {
        get { d.bool(forKey: Key.migrated) }
        set { d.set(newValue, forKey: Key.migrated) }
    }

    /// Advanced → "Reset local settings". Accounts and notification state are
    /// cleared by their own stores; this only touches preferences.
    func resetToDefaults() {
        for key in [Key.refreshMinutes, Key.summaryMode, Key.showPercentages,
                    Key.showCountdown, Key.onlyHighest, Key.backgroundOpacity,
                    Key.perAccountFormat,
                    Key.usageWarnings, Key.warningThreshold,
                    Key.authWarnings, Key.debugLogging, Key.includeIdentities] {
            d.removeObject(forKey: key)
        }
        registerDefaults()
    }
}
