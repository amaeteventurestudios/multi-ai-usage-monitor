import Foundation

/// How an account's credential can be obtained during onboarding.
///
/// These are the choices the Add Account flow offers, in the order it offers
/// them: the first is what almost everyone should use.
struct CredentialMethod {
    /// Short button/label text, e.g. "Use the account Claude Code is signed in to".
    var title: String
    /// One sentence explaining what will happen.
    var detail: String
    /// Where the credential will be read from.
    var source: CredentialSource
    /// True when the user has to pick a file before this can proceed.
    var requiresFileChoice: Bool
    /// True for the everyday path; the rest are advanced fallbacks.
    var isPrimary: Bool

    init(title: String, detail: String, source: CredentialSource,
         requiresFileChoice: Bool = false, isPrimary: Bool = false) {
        self.title = title
        self.detail = detail
        self.source = source
        self.requiresFileChoice = requiresFileChoice
        self.isPrimary = isPrimary
    }
}

/// The contract every provider adapter implements.
///
/// A provider is handed one account and returns that account's usage. It knows
/// nothing about the menu, the settings pane or the other accounts, which is
/// what makes a third provider a new file rather than a refactor.
protocol UsageProvider {
    var providerKind: ProviderKind { get }

    /// Non-secret status of the account's credential, for the settings pane.
    func credentialStatus(for account: AIAccount) -> CredentialStatus

    /// The ways this provider's credentials can be picked up, best first.
    func credentialMethods() -> [CredentialMethod]

    /// Ask the provider who the credential at `source` belongs to.
    ///
    /// This both proves the credential works and answers "which account is
    /// this". Identity is never guessed: a provider that will not say returns
    /// an unidentified result, and the UI says so.
    func discoverIdentity(source: CredentialSource,
                          completion: @escaping (Result<AccountIdentity, AccountError>) -> Void)

    /// Copy the credential at `source` into storage this app owns, keyed by
    /// account id, and return the source that now refers to it.
    ///
    /// This is what makes a saved account independent: afterwards the account
    /// no longer reads from whichever credential the provider's own tool
    /// happens to hold, so signing a different account into that tool cannot
    /// disturb it.
    func captureCredential(from source: CredentialSource,
                           forAccountID id: UUID) -> Result<CredentialSource, AccountError>

    /// Delete any credential copy this app owns for an account. Must never
    /// touch a credential owned by the provider's own tools.
    func discardCapturedCredential(forAccountID id: UUID)

    /// Last-ditch recovery before telling the user to reconnect: if the
    /// provider's own tool now happens to hold a live credential for *this same
    /// account*, adopt it. Calls back with nil when there is nothing safe to
    /// adopt — which is the answer whenever we cannot prove it is the same
    /// account.
    func silentReconnect(for account: AIAccount,
                         completion: @escaping (CredentialSource?) -> Void)

    /// Fetch usage. Completion may be called on any queue.
    func fetchUsage(for account: AIAccount,
                    completion: @escaping (Result<AccountUsage, Error>) -> Void)
}

extension UsageProvider {
    func discardCapturedCredential(forAccountID id: UUID) {
        Keychain.delete(service: AppInfo.appKeychainService, account: id.uuidString)
    }

    func silentReconnect(for account: AIAccount,
                         completion: @escaping (CredentialSource?) -> Void) { completion(nil) }
}

/// Lookup so callers never switch on provider kind themselves.
enum ProviderRegistry {
    static let claude = ClaudeUsageProvider()
    static let openAI = OpenAIUsageProvider()

    static func provider(for kind: ProviderKind) -> UsageProvider {
        switch kind {
        case .claude: return claude
        case .openAI: return openAI
        }
    }
}
