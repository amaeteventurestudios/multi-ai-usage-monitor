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
    /// Accounts we have already tried to recover silently since their last
    /// success, so one failing account cannot loop between adopt and retry.
    private var silentReconnectTried: Set<UUID> = []
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
        refreshIdentities()
        refreshAll()
        restartTimers()
    }

    /// Ask each provider who its accounts belong to, for any account we have
    /// not identified yet.
    ///
    /// This is what turns an account carried over from an earlier version —
    /// which had no identity at all — into "Claude (you@example.com)" without
    /// the user doing anything.
    func refreshIdentities() {
        for account in store.accounts where !account.isIdentified {
            ProviderRegistry.provider(for: account.provider)
                .discoverIdentity(source: account.credentialSource) { [weak self] result in
                    guard let self = self, case .success(let identity) = result,
                          identity.isIdentified else { return }
                    DispatchQueue.main.async {
                        guard self.store.account(id: account.id) != nil else { return }
                        self.store.setIdentity(identity, id: account.id)
                        Diagnostics.shared.info("identified a \(account.provider.rawValue) account")
                        self.notifyChanged()
                    }
                }
        }
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
            silentReconnectTried.remove(account.id)
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

            // Before telling anyone to reconnect, see whether the provider's own
            // tool now holds a live credential for this same account. If it
            // does, adopt it and try again — signing back in anywhere on this
            // Mac then revives the account with no reconnect step at all.
            let recoverable = accountError.kind == .expiredCredential
                || accountError.kind == .authenticationFailed
                || accountError.kind == .missingCredential
            if recoverable, account.hasCapturedCredential, !silentReconnectTried.contains(account.id) {
                silentReconnectTried.insert(account.id)
                states[account.id] = state
                ProviderRegistry.provider(for: account.provider)
                    .silentReconnect(for: account) { [weak self] newSource in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            guard let newSource = newSource else {
                                self.recordFailure(accountError, for: account)
                                return
                            }
                            self.store.setCredentialSource(newSource, id: account.id)
                            self.credentialStatus[account.id] = .detected
                            if let updated = self.store.account(id: account.id) {
                                self.refresh(updated)
                            }
                        }
                    }
                notifyChanged()
                return
            }
            recordFailure(accountError, for: account)
        }
        notifyChanged()
    }

    /// Record an account-local failure, keeping whatever numbers that account
    /// already had.
    private func recordFailure(_ accountError: AccountError, for account: AIAccount) {
        var state = states[account.id] ?? AccountRuntimeState()
        state.isRefreshing = false
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
            scheduleBackoffRetry(for: account, retryAfter: accountError.retryAfter)
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
            entries: MenuBarSummary.entries(accounts: store.accounts, states: states),
            mode: settings.menuBarSummaryMode,
            format: settings.perAccountFormat,
            showPercentages: settings.showPercentages,
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

    /// Save an account that onboarding has just identified.
    ///
    /// The credential is copied into storage this app owns *before* the account
    /// is saved, so a saved account is never left pointing at another tool's
    /// single credential slot. If the copy fails, nothing is saved.
    func saveOnboardedAccount(provider: ProviderKind,
                              identity: AccountIdentity,
                              source: CredentialSource,
                              resetOverrides: ResetOverrides = ResetOverrides())
        -> Result<AIAccount, AccountError> {

        if let existing = store.existingAccount(provider: provider, identity: identity) {
            return .failure(AccountError(
                kind: .duplicateAccount,
                message: "This account is already added as “\(existing.displayName)”.",
                recovery: "Use Reconnect on that account if its credential needs refreshing."))
        }

        let id = UUID()
        let adapter = ProviderRegistry.provider(for: provider)
        let captured: CredentialSource
        switch adapter.captureCredential(from: source, forAccountID: id) {
        case .success(let s): captured = s
        case .failure(let error): return .failure(error)
        }

        let account = AIAccount(id: id, provider: provider, identity: identity,
                                credentialSource: captured, resetOverrides: resetOverrides)
        let saved = store.add(account)
        refreshCredentialStatuses()
        refresh(saved)
        Diagnostics.shared.info("saved a new \(provider.rawValue) account from onboarding")
        return .success(saved)
    }

    /// Replace only an account's credential.
    ///
    /// The display name, reset rule, ordering, threshold and position are all
    /// preserved — reconnecting is about the credential and nothing else. A
    /// credential belonging to a *different* account is refused, since silently
    /// repointing an account at someone else's usage would be the worst
    /// possible outcome for a dashboard used to decide where to send work.
    func reconnect(accountID: UUID,
                   identity: AccountIdentity,
                   source: CredentialSource) -> Result<AIAccount, AccountError> {
        guard let account = store.account(id: accountID) else {
            return .failure(AccountError(kind: .missingCredential, message: "That account no longer exists."))
        }
        if let known = account.identity, known.isIdentified, identity.isIdentified,
           !known.matches(identity) {
            return .failure(AccountError(
                kind: .identityMismatch,
                message: "That credential belongs to \(identity.email ?? "a different account"), "
                       + "not to “\(account.displayName)”.",
                recovery: "Sign in as the right account and try again, or add this one separately."))
        }
        if let clash = store.existingAccount(provider: account.provider, identity: identity,
                                             excluding: accountID) {
            return .failure(AccountError(
                kind: .duplicateAccount,
                message: "That credential belongs to “\(clash.displayName)”, which is already added."))
        }

        let adapter = ProviderRegistry.provider(for: account.provider)
        switch adapter.captureCredential(from: source, forAccountID: accountID) {
        case .failure(let error):
            return .failure(error)
        case .success(let captured):
            store.setCredentialSource(captured, id: accountID)
            if identity.isIdentified { store.setIdentity(identity, id: accountID) }
            silentReconnectTried.remove(accountID)
            states[accountID]?.error = nil
            refreshCredentialStatuses()
            if let updated = store.account(id: accountID) { refresh(updated) }
            Diagnostics.shared.info("reconnected an account; only its credential changed")
            return .success(store.account(id: accountID) ?? account)
        }
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
        if let account = store.account(id: id) {
            // Only ever a copy this app owns. Claude Code's item and
            // ~/.codex/auth.json are never touched.
            ProviderRegistry.provider(for: account.provider).discardCapturedCredential(forAccountID: id)
        }
        silentReconnectTried.remove(id)
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
