import Foundation

/// Owns the accounts, their live state, and the refresh cycle.
///
/// Every account is refreshed independently and concurrently: one signed-out,
/// expired or rate-limited account never delays or blanks another. Per-account
/// backoff keeps a failing provider from being hammered while the healthy ones
/// keep their normal cadence.
final class UsageCoordinator {

    let store: AccountStore
    let settings: AppSettings
    let notifications: NotificationTracker

    /// Called on the main queue whenever anything the UI renders has changed.
    var onChange: (() -> Void)?

    private(set) var states: [UUID: AccountRuntimeState] = [:]
    private(set) var credentialStatus: [UUID: CredentialStatus] = [:]
    private(set) var lastUpdated: Date?

    /// Accounts currently in flight, so a manual refresh during a poll does not
    /// start a second request for the same account.
    private var inFlight: Set<UUID> = []
    private var backoffAttempt: [UUID: Int] = [:]
    private var retryWork: [UUID: DispatchWorkItem] = [:]

    private var pollTimer: Timer?
    private var tickTimer: Timer?

    /// Usage older than this is labelled stale in the UI. Generous, because the
    /// windows themselves are hours to days long.
    static let staleAfter: TimeInterval = 15 * 60

    init(store: AccountStore, settings: AppSettings, notifications: NotificationTracker) {
        self.store = store
        self.settings = settings
        self.notifications = notifications
    }

    // MARK: - Lifecycle

    func start() {
        refreshCredentialStatuses()
        refreshAll()
        restartTimers()
    }

    func restartTimers() {
        pollTimer?.invalidate()
        if let interval = settings.refreshInterval {
            pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.refreshAll()
            }
        }
        // Local-only re-render so countdowns and "stale" labels stay honest
        // without touching the network.
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.notifyChanged()
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        for (_, w) in retryWork { w.cancel() }
        retryWork.removeAll()
    }

    // MARK: - Credential status

    func refreshCredentialStatuses() {
        var out: [UUID: CredentialStatus] = [:]
        for account in store.accounts {
            out[account.id] = ProviderRegistry.provider(for: account.provider)
                .credentialStatus(for: account)
        }
        credentialStatus = out
    }

    // MARK: - Refresh

    func refreshAll() {
        let accounts = store.enabledAccounts
        guard !accounts.isEmpty else { notifyChanged(); return }
        Diagnostics.shared.debug("refreshing \(accounts.count) account(s)")
        // Fired together: independent accounts do not queue behind each other.
        for account in accounts { refresh(account) }
    }

    func refresh(accountID: UUID) {
        guard let a = store.account(id: accountID) else { return }
        refresh(a)
    }

    private func refresh(_ account: AIAccount) {
        guard account.enabled else { return }
        guard !inFlight.contains(account.id) else {
            Diagnostics.shared.debug("skipping \(account.id): already refreshing")
            return
        }
        inFlight.insert(account.id)
        setRefreshing(true, for: account.id)

        ProviderRegistry.provider(for: account.provider)
            .fetchUsage(for: account) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handle(result, for: account)
                }
            }
    }

    private func setRefreshing(_ value: Bool, for id: UUID) {
        var s = states[id] ?? AccountRuntimeState()
        s.isRefreshing = value
        states[id] = s
        notifyChanged()
    }

    private func handle(_ result: Result<AccountUsage, Error>, for account: AIAccount) {
        inFlight.remove(account.id)
        var state = states[account.id] ?? AccountRuntimeState()
        state.isRefreshing = false

        switch result {
        case .success(let usage):
            backoffAttempt[account.id] = 0
            retryWork[account.id]?.cancel()
            retryWork[account.id] = nil

            state.usage = usage
            state.error = nil
            state.lastSuccess = usage.fetchedAt
            states[account.id] = state
            lastUpdated = Date()
            credentialStatus[account.id] = .detected

            for alert in notifications.usageAlerts(for: account, usage: usage, settings: settings) {
                NotificationPoster.post(alert)
            }
            _ = notifications.authAlert(for: account, error: nil, settings: settings)

        case .failure(let error):
            let accountError = (error as? AccountError) ?? HTTP.classify(error, provider: account.provider)
            // The previous snapshot stays exactly where it is. A failed refresh
            // costs the user the freshness of the number, never the number.
            state.error = accountError
            states[account.id] = state
            credentialStatus[account.id] = ProviderRegistry.provider(for: account.provider)
                .credentialStatus(for: account)

            Diagnostics.shared.warning("account \(account.id) refresh failed: \(accountError.kind.rawValue)")

            if let alert = notifications.authAlert(for: account, error: accountError, settings: settings) {
                NotificationPoster.post(alert)
            }
            if accountError.kind == .rateLimited || accountError.kind == .providerUnavailable {
                let retryAfter = (error as? HTTPError)?.retryAfter
                scheduleBackoffRetry(for: account, retryAfter: retryAfter)
            }
        }
        notifyChanged()
    }

    /// One retry per failure, per account, after a 429/5xx.
    ///
    /// When the server sends `Retry-After` we wait at least that long plus a
    /// little jitter — never less, or we keep the window armed. Otherwise
    /// exponential backoff (30s, 60s, 120s, … capped at 30 min) with jitter,
    /// under a two-hour ceiling in case a server returns something absurd. The
    /// steady poll timer keeps running underneath, so this only ever fetches
    /// sooner than the next scheduled poll, never later.
    private func scheduleBackoffRetry(for account: AIAccount, retryAfter: TimeInterval?) {
        let attempt = (backoffAttempt[account.id] ?? 0) + 1
        backoffAttempt[account.id] = attempt

        let ceiling: TimeInterval = 7200
        let delay: TimeInterval
        if let ra = retryAfter {
            delay = min(ceiling, ra + Double.random(in: 0...15))
        } else {
            let expo = min(1800, 30 * pow(2.0, Double(attempt - 1)))
            delay = expo + Double.random(in: 0...(max(1, expo) * 0.25))
        }

        var state = states[account.id] ?? AccountRuntimeState()
        if var err = state.error {
            let secs = Int(delay.rounded())
            let pretty = secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs)s"
            err.recovery = "Retrying in \(pretty)."
            state.error = err
            states[account.id] = state
        }

        retryWork[account.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(accountID: account.id) }
        retryWork[account.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Rendering helpers

    /// The metrics to draw for an account, with staleness already applied so the
    /// UI never has to work out whether a number is current.
    func displayMetrics(for account: AIAccount, now: Date = Date()) -> [UsageMetric] {
        let state = states[account.id]
        guard let usage = state?.usage else { return [] }
        return UsageCoordinator.applyStaleness(to: usage.metrics,
                                               fetchedAt: usage.fetchedAt,
                                               hasError: state?.error != nil,
                                               now: now)
    }

    /// A snapshot is stale once it is older than `staleAfter`, or as soon as a
    /// refresh fails — the numbers stay, clearly labelled as no longer current.
    /// States that are not a live value (unsupported, error…) are left alone.
    static func applyStaleness(to metrics: [UsageMetric],
                               fetchedAt: Date,
                               hasError: Bool,
                               now: Date = Date()) -> [UsageMetric] {
        let isStale = now.timeIntervalSince(fetchedAt) > staleAfter || hasError
        guard isStale else { return metrics }
        return metrics.map { metric in
            var m = metric
            if m.state == .available { m.state = .stale }
            return m
        }
    }

    func state(for account: AIAccount) -> AccountRuntimeState {
        states[account.id] ?? AccountRuntimeState()
    }

    func menuBarTitle() -> String? {
        MenuBarSummary.title(
            entries: MenuBarSummary.entries(accounts: store.accounts, states: states, store: store),
            mode: settings.menuBarSummaryMode,
            showPercentages: settings.showPercentages,
            showBadges: settings.showProviderBadges,
            onlyHighest: settings.onlyHighestInMenuBar)
    }

    // MARK: - Account management

    /// Adds an account and immediately fetches it, so the user sees the result
    /// of what they just configured rather than waiting for the next poll.
    @discardableResult
    func addAccount(_ account: AIAccount) -> AIAccount {
        let added = store.add(account)
        refreshCredentialStatuses()
        refresh(added)
        return added
    }

    func updateAccount(_ account: AIAccount) {
        store.update(account)
        refreshCredentialStatuses()
        if account.enabled {
            refresh(account)
        } else {
            states[account.id]?.error = nil
            notifyChanged()
        }
    }

    /// Removes an account, and with it only the credential copy this app owns.
    /// Claude Code's item and ~/.codex/auth.json are never touched.
    func removeAccount(id: UUID) {
        if let account = store.account(id: id),
           case .appKeychain = account.credentialSource {
            ClaudeCredentialStore.deleteImportedCredential(forAccountID: id)
        }
        retryWork[id]?.cancel()
        retryWork[id] = nil
        states[id] = nil
        credentialStatus[id] = nil
        store.remove(id: id)
        notifyChanged()
    }

    func moveAccount(id: UUID, by offset: Int) {
        store.move(id: id, by: offset)
        notifyChanged()
    }

    private func notifyChanged() {
        if Thread.isMainThread { onChange?() }
        else { DispatchQueue.main.async { self.onChange?() } }
    }
}
