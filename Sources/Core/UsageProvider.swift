import Foundation

/// The contract every provider adapter implements.
///
/// A provider is handed one account and returns that account's usage. It knows
/// nothing about the menu, the settings pane or the other accounts, which is
/// what makes a third provider a new file rather than a refactor.
protocol UsageProvider {
    var providerKind: ProviderKind { get }

    /// Non-secret status of the account's credential, for the settings pane.
    func credentialStatus(for account: AIAccount) -> CredentialStatus

    /// A suggested display name derived from local credential metadata, or nil
    /// when the credential does not identify itself. Never invented.
    func suggestedDisplayName(for source: CredentialSource) -> String?

    /// Fetch usage. Completion may be called on any queue.
    func fetchUsage(for account: AIAccount,
                    completion: @escaping (Result<AccountUsage, Error>) -> Void)
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
