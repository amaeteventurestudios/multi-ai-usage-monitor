import Foundation

/// Persistence for the account list.
///
/// Accounts are non-secret metadata only: a display name, an ordering, which
/// credential source to consult, and a reset rule. The credential itself never
/// appears here — it lives in the Keychain or in a file another tool owns.
final class AccountStore {
    private let d: UserDefaults
    private let key = "accounts.v1"

    private(set) var accounts: [AIAccount] = []

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        load()
    }

    // MARK: Loading and saving

    private func load() {
        guard let data = d.data(forKey: key) else { accounts = []; return }
        do {
            let decoded = try JSONDecoder().decode([AIAccount].self, from: data)
            accounts = decoded.sorted { $0.order < $1.order }
        } catch {
            // A corrupt list must not wedge the app on every launch. Start
            // empty; migration will re-detect whatever is on this Mac.
            Diagnostics.shared.error("account list unreadable, starting empty: \(error)")
            accounts = []
        }
    }

    private func save() {
        normalizeOrder()
        do {
            d.set(try JSONEncoder().encode(accounts), forKey: key)
        } catch {
            Diagnostics.shared.error("could not persist accounts: \(error)")
        }
    }

    private func normalizeOrder() {
        for (i, _) in accounts.enumerated() { accounts[i].order = i }
    }

    // MARK: Queries

    var enabledAccounts: [AIAccount] { accounts.filter { $0.enabled } }

    func accounts(for provider: ProviderKind) -> [AIAccount] {
        accounts.filter { $0.provider == provider }
    }

    func account(id: UUID) -> AIAccount? { accounts.first { $0.id == id } }

    /// Short menu bar badge for an account: "C" when it is the only Claude
    /// account, "C1"/"C2" when there is more than one. Stable as long as the
    /// ordering is.
    func badge(for account: AIAccount) -> String {
        let siblings = accounts.filter { $0.provider == account.provider }
        guard siblings.count > 1,
              let index = siblings.firstIndex(where: { $0.id == account.id }) else {
            return account.provider.badgeLetter
        }
        return "\(account.provider.badgeLetter)\(index + 1)"
    }

    // MARK: Mutations

    @discardableResult
    func add(_ account: AIAccount) -> AIAccount {
        var a = account
        a.order = accounts.count
        accounts.append(a)
        save()
        return a
    }

    func update(_ account: AIAccount) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        save()
    }

    /// Removes the account. The caller is responsible for deleting any
    /// app-owned Keychain copy first — see `AccountManager.remove`.
    func remove(id: UUID) {
        accounts.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].enabled = enabled
        save()
    }

    /// Set a name the user typed. An empty string clears the override, so the
    /// account goes back to being named after whoever it belongs to.
    func rename(id: UUID, to name: String?) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].customDisplayName = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// Record who an account belongs to, leaving everything else alone.
    func setIdentity(_ identity: AccountIdentity, id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].identity = identity
        save()
    }

    /// Replace only an account's credential reference. Used by Reconnect, which
    /// must preserve the name, reset rule, ordering and notification settings.
    func setCredentialSource(_ source: CredentialSource, id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].credentialSource = source
        save()
    }

    /// An already-saved account with the same provider identity, if any. This is
    /// what stops the same account being added twice.
    func existingAccount(provider: ProviderKind,
                         identity: AccountIdentity,
                         excluding excludedID: UUID? = nil) -> AIAccount? {
        accounts.first { account in
            account.provider == provider
                && account.id != excludedID
                && (account.identity?.matches(identity) ?? false)
        }
    }

    /// Reordering is expressed as "move one step", which is what the settings
    /// pane offers. Drag-and-drop would need an NSTableView data source for a
    /// list that is usually two to four rows long; Move Up / Move Down is the
    /// same capability with far less machinery. See docs/DECISIONS.md.
    func move(id: UUID, by offset: Int) {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard to >= 0, to < accounts.count else { return }
        let a = accounts.remove(at: from)
        accounts.insert(a, at: to)
        save()
    }

    func replaceAll(_ newAccounts: [AIAccount]) {
        accounts = newAccounts
        save()
    }

    func removeAll() {
        accounts = []
        save()
    }
}
