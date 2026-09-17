import Foundation

// MARK: - Providers

/// A service we can report usage for. Adding a provider means adding a case
/// here plus a `UsageProvider` implementation — nothing in the UI hard-codes
/// which providers exist.
enum ProviderKind: String, Codable, CaseIterable {
    case claude
    case openAI = "openai"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "OpenAI"
        }
    }

    /// Single letter used to build a menu bar badge, e.g. "C1", "G2".
    var badgeLetter: String {
        switch self {
        case .claude: return "C"
        case .openAI: return "G"
        }
    }
}

// MARK: - Credential sources

/// Where an account's credential comes from. The app never signs anyone in; it
/// either reads a credential another tool owns, or reads a copy the user
/// explicitly imported into this app's own Keychain service.
enum CredentialSource: Equatable, Codable {
    /// The login-Keychain item Claude Code writes ("Claude Code-credentials").
    case claudeCodeKeychain
    /// A copy the user imported, stored under this app's own Keychain service
    /// and addressed by the owning account's id. Removing the account removes
    /// only this item.
    case appKeychain(id: String)
    /// A JSON credential file the user pointed at (a Claude credential blob, or
    /// a Codex `auth.json`). Read-only — the app never writes these.
    case file(path: String)
    /// The default Codex/ChatGPT credential at ~/.codex/auth.json.
    case codexDefault

    /// Short, secret-free description for the settings pane and diagnostics.
    var kindLabel: String {
        switch self {
        case .claudeCodeKeychain: return "Keychain · Claude Code"
        case .appKeychain: return "Keychain · this app"
        case .file: return "File"
        case .codexDefault: return "File · Codex default"
        }
    }

    /// Human-readable location. For file sources this is a path, which may
    /// contain the user's home directory — abbreviated for display.
    var locationLabel: String {
        switch self {
        case .claudeCodeKeychain: return ClaudeCredentialStore.keychainService
        case .appKeychain: return AppInfo.appKeychainService
        case .file(let path): return (path as NSString).abbreviatingWithTildeInPath
        case .codexDefault: return (CodexCredentialStore.defaultPath as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Which providers may legitimately use this source.
    func isValid(for provider: ProviderKind) -> Bool {
        switch (self, provider) {
        case (.claudeCodeKeychain, .claude), (.appKeychain, .claude), (.file, .claude): return true
        case (.codexDefault, .openAI), (.file, .openAI): return true
        default: return false
        }
    }

    // Encoded as a tagged object so the on-disk shape stays readable and stable.
    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "claudeCodeKeychain": self = .claudeCodeKeychain
        case "appKeychain":        self = .appKeychain(id: try c.decode(String.self, forKey: .value))
        case "file":               self = .file(path: try c.decode(String.self, forKey: .value))
        case "codexDefault":       self = .codexDefault
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown credential source \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claudeCodeKeychain: try c.encode("claudeCodeKeychain", forKey: .kind)
        case .codexDefault:       try c.encode("codexDefault", forKey: .kind)
        case .appKeychain(let id):
            try c.encode("appKeychain", forKey: .kind); try c.encode(id, forKey: .value)
        case .file(let path):
            try c.encode("file", forKey: .kind); try c.encode(path, forKey: .value)
        }
    }
}

/// What we found when we last looked at a credential source. Never carries the
/// credential itself.
enum CredentialStatus: String, Codable {
    case detected      // present and usable
    case missing       // nothing there
    case expired       // present but past its expiry
    case invalid       // present but not in a shape we understand
    case unreadable    // present but we could not read it (permissions, etc.)

    var displayName: String {
        switch self {
        case .detected:   return "Detected"
        case .missing:    return "Missing"
        case .expired:    return "Expired"
        case .invalid:    return "Invalid"
        case .unreadable: return "Unreadable"
        }
    }
}

// MARK: - Reset overrides

/// A locally configured weekly reset, used when the provider does not tell us
/// when a window rolls over. Weekday follows `Calendar` numbering: 1 = Sunday
/// … 7 = Saturday.
struct WeeklyResetRule: Codable, Equatable {
    var weekday: Int
    var hour: Int
    var minute: Int

    init(weekday: Int, hour: Int, minute: Int) {
        self.weekday = min(7, max(1, weekday))
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    static let mondayNames = [1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
                              5: "Thursday", 6: "Friday", 7: "Saturday"]

    var weekdayName: String { WeeklyResetRule.mondayNames[weekday] ?? "Monday" }
}

/// How an account decides when its windows reset.
struct ResetOverrides: Codable, Equatable {
    /// When true (the default) a provider-supplied reset timestamp always wins
    /// and `weekly` is only a fallback for metrics the provider leaves blank.
    var preferProviderReset: Bool = true
    /// Optional local weekly schedule. `nil` means "unknown unless the provider
    /// tells us".
    var weekly: WeeklyResetRule?
}

// MARK: - Accounts

/// One configured account. Accounts — not providers — are the unit the app
/// refreshes, renders, alerts on and stores credentials for, so two accounts on
/// the same provider are completely independent.
struct AIAccount: Codable, Equatable, Identifiable {
    var id: UUID
    var provider: ProviderKind
    var displayName: String
    var enabled: Bool
    var order: Int
    var credentialSource: CredentialSource
    var resetOverrides: ResetOverrides
    /// nil means "use the global notification threshold".
    var notificationThresholdPercent: Int?

    init(id: UUID = UUID(),
         provider: ProviderKind,
         displayName: String,
         enabled: Bool = true,
         order: Int = 0,
         credentialSource: CredentialSource,
         resetOverrides: ResetOverrides = ResetOverrides(),
         notificationThresholdPercent: Int? = nil) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.enabled = enabled
        self.order = order
        self.credentialSource = credentialSource
        self.resetOverrides = resetOverrides
        self.notificationThresholdPercent = notificationThresholdPercent
    }
}

// MARK: - Usage metrics

/// Lifecycle of a single metric. Every state renders as something specific in
/// the menu — there is no blank row and no invented number.
enum MetricState: String, Codable {
    case available
    case loading
    case stale
    case unsupported
    case authenticationRequired
    case rateLimited
    case error
}

/// Severity band for a usage value, mapped to colour by the UI layer.
enum UsageSeverity {
    case normal, warning, high, critical

    /// Thresholds are expressed in *used* percent.
    static func forUsedPercent(_ p: Double) -> UsageSeverity {
        switch p {
        case ..<60:  return .normal
        case ..<80:  return .warning
        case ..<95:  return .high
        default:     return .critical
        }
    }
}

/// One usage allowance. Percentage-based and count-based allowances share this
/// type so the menu can render both without special cases, and so a metric we
/// cannot read yet still has a place to live (state `.unsupported`).
///
/// Percentages are always *used*, never remaining. The UI says so explicitly.
struct UsageMetric: Codable, Equatable {
    var id: String
    var name: String

    var usedPercent: Double?
    var usedCount: Int?
    var limitCount: Int?

    /// When this window rolls over, if known.
    var resetsAt: Date?
    /// True when `resetsAt` came from the provider rather than a local override.
    var resetFromProvider: Bool
    /// Provider's own words for the window, e.g. "5-hour", "Weekly".
    var windowDescription: String?
    /// A short, secret-free explanation shown under the row for non-available
    /// states (e.g. "Not detectable yet", "Reconnect required").
    var detail: String?

    var lastUpdated: Date?
    var state: MetricState

    init(id: String,
         name: String,
         usedPercent: Double? = nil,
         usedCount: Int? = nil,
         limitCount: Int? = nil,
         resetsAt: Date? = nil,
         resetFromProvider: Bool = false,
         windowDescription: String? = nil,
         detail: String? = nil,
         lastUpdated: Date? = nil,
         state: MetricState = .available) {
        self.id = id
        self.name = name
        self.usedPercent = usedPercent
        self.usedCount = usedCount
        self.limitCount = limitCount
        self.resetsAt = resetsAt
        self.resetFromProvider = resetFromProvider
        self.windowDescription = windowDescription
        self.detail = detail
        self.lastUpdated = lastUpdated
        self.state = state
    }

    var remainingCount: Int? {
        guard let used = usedCount, let limit = limitCount else { return nil }
        return max(0, limit - used)
    }

    var remainingPercent: Double? {
        guard let used = usedPercent else { return nil }
        return max(0, 100 - used)
    }

    /// Percent for a count-based metric that reports no percentage of its own.
    var effectiveUsedPercent: Double? {
        if let p = usedPercent { return p }
        if let used = usedCount, let limit = limitCount, limit > 0 {
            return Double(used) / Double(limit) * 100
        }
        return nil
    }

    var isRenderableValue: Bool {
        (state == .available || state == .stale) && effectiveUsedPercent != nil
    }
}

/// Everything known about one account after a refresh attempt.
struct AccountUsage: Codable, Equatable {
    var accountID: UUID
    var metrics: [UsageMetric]
    /// Provider-reported identity, e.g. a plan name. May be nil.
    var accountLabel: String?
    /// Free text the provider gave us that has no percentage (e.g. a credit
    /// balance with no cap).
    var notes: [String]
    var fetchedAt: Date

    init(accountID: UUID,
         metrics: [UsageMetric],
         accountLabel: String? = nil,
         notes: [String] = [],
         fetchedAt: Date = Date()) {
        self.accountID = accountID
        self.metrics = metrics
        self.accountLabel = accountLabel
        self.notes = notes
        self.fetchedAt = fetchedAt
    }

    /// The metric mirrored into the menu bar: the highest *used* percentage we
    /// can actually render. Deliberately the worst number, because that is the
    /// one a glance needs to catch.
    var headlineMetric: UsageMetric? {
        metrics.filter { $0.isRenderableValue }
            .max { ($0.effectiveUsedPercent ?? 0) < ($1.effectiveUsedPercent ?? 0) }
    }
}

/// What the UI renders for one account: its last usage (possibly stale), plus
/// any account-local failure. One account failing never removes another's data.
struct AccountRuntimeState: Equatable {
    var usage: AccountUsage?
    var error: AccountError?
    var isRefreshing: Bool = false
    /// Last time a fetch for this account succeeded.
    var lastSuccess: Date?
}

/// An account-local failure, classified so the UI can say what to do about it
/// without ever echoing a credential.
struct AccountError: Error, Equatable, Codable {
    enum Kind: String, Codable {
        case missingCredential
        case expiredCredential
        case authenticationFailed
        case rateLimited
        case network
        case parsing
        case invalidPath
        case providerUnavailable
    }
    var kind: Kind
    var message: String
    /// Optional next step, e.g. "Open Claude Code to sign in again."
    var recovery: String?

    var metricState: MetricState {
        switch kind {
        case .missingCredential, .expiredCredential, .authenticationFailed:
            return .authenticationRequired
        case .rateLimited:
            return .rateLimited
        default:
            return .error
        }
    }
}
