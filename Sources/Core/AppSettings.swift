import Foundation

/// How much the menu bar title says.
enum MenuBarSummaryMode: String, CaseIterable, Codable {
    /// Every enabled account: "C1 12% · C2 43% · G1 88%".
    case compact
    /// Worst account per provider: "Claude 43% · OpenAI 88%".
    case provider
    /// Just a marker: "AI".
    case minimal

    var displayName: String {
        switch self {
        case .compact:  return "Compact — show each account"
        case .provider: return "Provider — highest usage per provider"
        case .minimal:  return "Minimal — just a marker"
        }
    }

    /// A sentence saying what will actually appear in the menu bar, because the
    /// mode names alone left people guessing.
    var explanation: String {
        switch self {
        case .compact:
            return "One short badge per enabled account, e.g. “C1 12% · C2 43% · G 88%”."
        case .provider:
            return "The highest current usage for each provider, e.g. “Claude 43% · OpenAI 88%”."
        case .minimal:
            return "Just “AI”, with an exclamation mark if an account needs attention."
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
        static let showBadges = "display.showProviderBadges"
        static let showCountdown = "display.showResetCountdown"
        static let onlyHighest = "display.onlyHighestInMenuBar"
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
            Key.summaryMode: MenuBarSummaryMode.compact.rawValue,
            Key.showPercentages: true,
            Key.showBadges: true,
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
        get { MenuBarSummaryMode(rawValue: d.string(forKey: Key.summaryMode) ?? "") ?? .compact }
        set { d.set(newValue.rawValue, forKey: Key.summaryMode) }
    }

    var showPercentages: Bool {
        get { d.bool(forKey: Key.showPercentages) }
        set { d.set(newValue, forKey: Key.showPercentages) }
    }
    var showProviderBadges: Bool {
        get { d.bool(forKey: Key.showBadges) }
        set { d.set(newValue, forKey: Key.showBadges) }
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
        for key in [Key.refreshMinutes, Key.summaryMode, Key.showPercentages, Key.showBadges,
                    Key.showCountdown, Key.onlyHighest, Key.backgroundOpacity,
                    Key.usageWarnings, Key.warningThreshold,
                    Key.authWarnings, Key.debugLogging, Key.includeIdentities] {
            d.removeObject(forKey: key)
        }
        registerDefaults()
    }
}
