// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Umanah. See NOTICE.

import Foundation

/// Claude (Anthropic) usage, read from the OAuth usage endpoint using the
/// credential Claude Code already holds.
final class ClaudeUsageProvider: UsageProvider {
    let providerKind: ProviderKind = .claude

    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    /// Names the account a credential belongs to — e-mail, a stable account
    /// uuid, and the plan. This is what lets a saved account be called
    /// "Claude (you@example.com)" instead of "Claude Account 2".
    static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    /// Claude Code's public OAuth client id — a published client identifier,
    /// not a secret.
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Tokens refreshed for a file-backed account, kept for this session only.
    /// We refuse to rewrite a credential file another tool owns, but there is no
    /// reason to make the user re-export on every poll.
    private var sessionTokens: [UUID: ClaudeCredentials] = [:]
    private let lock = NSLock()

    func credentialStatus(for account: AIAccount) -> CredentialStatus {
        ClaudeCredentialStore.status(of: account.credentialSource)
    }

    func credentialMethods() -> [CredentialMethod] {
        [
            CredentialMethod(
                title: "Import the current Claude Code account",
                detail: "This app copies that credential into its own Keychain entry, so you "
                      + "can switch Claude Code to a different account afterwards and this one "
                      + "keeps working.",
                source: .claudeCodeKeychain,
                isPrimary: true,
                preflightHeading: "Current Claude Code account",
                // Claude Code signs in separately from claude.ai in a browser and
                // from the Claude desktop app. Someone looking at a different
                // account in one of those would otherwise import a credential
                // they did not expect, and only notice later.
                disclaimer: "This reads Claude Code's terminal/CLI credential. Your Claude "
                          + "browser or desktop-app login may be a different account.",
                switchInstruction: "Switch Claude Code to the account you want to import, "
                                 + "then click Check Again."),
            CredentialMethod(
                title: "Read a credential file instead",
                detail: "Point at a JSON file holding a Claude credential. The file is only "
                      + "ever read, never written.",
                source: .file(path: ""),
                requiresFileChoice: true),
        ]
    }

    /// Ask Anthropic who this credential belongs to.
    ///
    /// Refreshes an expired token first, so onboarding does not fail on a stale
    /// credential that is otherwise perfectly good.
    func discoverIdentity(source: CredentialSource,
                          completion: @escaping (Result<AccountIdentity, AccountError>) -> Void) {
        guard let creds = ClaudeCredentialStore.read(source: source) else {
            completion(.failure(AccountError(
                kind: .missingCredential,
                message: "No Claude credential found there.",
                recovery: recoveryHint(for: source))))
            return
        }
        let probe = AIAccount(provider: .claude, credentialSource: source)
        if creds.isExpired {
            refreshToken(creds, account: probe) { [weak self] refreshed in
                guard let self = self else { return }
                guard let refreshed = refreshed else {
                    completion(.failure(AccountError(
                        kind: .expiredCredential,
                        message: "That credential has expired and could not be renewed.",
                        recovery: "Sign in again with Claude Code, then try once more.")))
                    return
                }
                self.loadProfile(token: refreshed.accessToken, creds: refreshed, completion: completion)
            }
            return
        }
        loadProfile(token: creds.accessToken, creds: creds, completion: completion)
    }

    private func loadProfile(token: String,
                             creds: ClaudeCredentials,
                             completion: @escaping (Result<AccountIdentity, AccountError>) -> Void) {
        HTTP.getJSON(url: ClaudeUsageProvider.profileURL,
                     headers: ["Authorization": "Bearer \(token)",
                               "anthropic-beta": "oauth-2025-04-20"]) { result in
            switch result {
            case .success(let obj):
                completion(.success(ClaudeIdentityParser.parse(obj, credentials: creds)))
            case .failure(let error):
                let classified = HTTP.classify(error, provider: .claude)
                // A working credential whose profile we cannot read is still
                // usable for usage; report what the plan says and let the UI
                // offer a local label rather than blocking onboarding.
                if classified.kind == .parsing || classified.kind == .providerUnavailable {
                    completion(.success(ClaudeIdentityParser.unidentified(credentials: creds)))
                } else {
                    completion(.failure(classified))
                }
            }
        }
    }

    func captureCredential(from source: CredentialSource,
                           forAccountID id: UUID) -> Result<CredentialSource, AccountError> {
        guard let creds = ClaudeCredentialStore.read(source: source) else {
            return .failure(AccountError(kind: .missingCredential,
                                         message: "No Claude credential found there.",
                                         recovery: recoveryHint(for: source)))
        }
        let destination = CredentialSource.appKeychain(id: id.uuidString)
        guard ClaudeCredentialStore.write(creds, to: destination) else {
            return .failure(AccountError(kind: .unreadableCredential,
                                         message: "Could not save the credential to the Keychain."))
        }
        return .success(destination)
    }

    /// Claude tokens carry a refresh token, so an expired captured credential
    /// normally renews itself. This covers the case where the refresh token
    /// itself is dead but Claude Code has since been signed back in to the
    /// *same* account — then its credential is safe to adopt.
    func silentReconnect(for account: AIAccount,
                         completion: @escaping (CredentialSource?) -> Void) {
        guard account.hasCapturedCredential,
              let identity = account.identity, identity.isIdentified,
              let live = ClaudeCredentialStore.read(source: .claudeCodeKeychain),
              !live.isExpired else { completion(nil); return }

        // The credential itself does not name its account, so ask the provider
        // before adopting anything. Without proof that it is the same account,
        // we do nothing and let the user reconnect deliberately.
        discoverIdentity(source: .claudeCodeKeychain) { [weak self] result in
            guard let self = self,
                  case .success(let liveIdentity) = result,
                  liveIdentity.matches(identity),
                  case .success(let source) = self.captureCredential(from: .claudeCodeKeychain,
                                                                     forAccountID: account.id) else {
                completion(nil); return
            }
            Diagnostics.shared.info("adopted a fresh Claude Code credential for a matching saved account")
            completion(source)
        }
    }

    func fetchUsage(for account: AIAccount,
                    completion: @escaping (Result<AccountUsage, Error>) -> Void) {
        guard let creds = currentCredentials(for: account) else {
            completion(.failure(AccountError(
                kind: .missingCredential,
                message: "No Claude credential for this account.",
                recovery: recoveryHint(for: account.credentialSource))))
            return
        }

        if creds.isExpired {
            refreshToken(creds, account: account) { [weak self] refreshed in
                guard let self = self else { return }
                guard let refreshed = refreshed else {
                    completion(.failure(AccountError(
                        kind: .expiredCredential,
                        message: "Credential expired and could not be renewed.",
                        recovery: self.recoveryHint(for: account.credentialSource))))
                    return
                }
                self.load(account: account, token: refreshed.accessToken,
                          allowRefresh: false, completion: completion)
            }
            return
        }
        load(account: account, token: creds.accessToken, allowRefresh: true, completion: completion)
    }

    // MARK: - Internals

    private func currentCredentials(for account: AIAccount) -> ClaudeCredentials? {
        lock.lock()
        let cached = sessionTokens[account.id]
        lock.unlock()
        // A cached, still-valid token only applies to sources we cannot write
        // back to; anywhere else the stored credential is authoritative.
        if case .file = account.credentialSource, let c = cached, !c.isExpired { return c }
        return ClaudeCredentialStore.read(source: account.credentialSource)
    }

    private func recoveryHint(for source: CredentialSource) -> String {
        switch source {
        case .claudeCodeKeychain: return "Open Claude Code and sign in, then Refresh."
        case .appKeychain:        return "Reconnect this account in Settings to import a fresh credential."
        case .file(let path):     return "Check the credential file at \((path as NSString).abbreviatingWithTildeInPath)."
        case .codexDefault:       return "This account is misconfigured; choose a Claude credential source."
        }
    }

    private func refreshToken(_ creds: ClaudeCredentials,
                              account: AIAccount,
                              completion: @escaping (ClaudeCredentials?) -> Void) {
        guard let refresh = creds.refreshToken else { completion(nil); return }
        HTTP.postJSON(url: ClaudeUsageProvider.tokenURL,
                      body: ["grant_type": "refresh_token",
                             "refresh_token": refresh,
                             "client_id": ClaudeUsageProvider.oauthClientID]) { [weak self] result in
            guard let self = self else { completion(nil); return }
            guard case .success(let obj) = result,
                  let access = obj["access_token"] as? String else {
                Diagnostics.shared.warning("Claude token refresh failed for account \(account.id)")
                completion(nil); return
            }
            var updated = creds
            updated.accessToken = access
            if let r = obj["refresh_token"] as? String { updated.refreshToken = r }
            if let exp = obj["expires_in"] as? Double {
                updated.expiresAt = Date().timeIntervalSince1970 * 1000 + exp * 1000
            }
            // Persist where we're allowed to; otherwise hold it for this session.
            if !ClaudeCredentialStore.write(updated, to: account.credentialSource) {
                self.lock.lock()
                self.sessionTokens[account.id] = updated
                self.lock.unlock()
            }
            completion(updated)
        }
    }

    private func load(account: AIAccount,
                      token: String,
                      allowRefresh: Bool,
                      completion: @escaping (Result<AccountUsage, Error>) -> Void) {
        HTTP.getJSON(url: ClaudeUsageProvider.usageURL,
                     headers: ["Authorization": "Bearer \(token)",
                               "anthropic-beta": "oauth-2025-04-20"]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let obj):
                do {
                    completion(.success(try ClaudeUsageParser.parse(obj, account: account)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                // A 401 on a token we believed current: re-mint once, then give up.
                if let http = error as? HTTPError, http.status == 401, allowRefresh,
                   let creds = ClaudeCredentialStore.read(source: account.credentialSource) {
                    self.refreshToken(creds, account: account) { refreshed in
                        guard let refreshed = refreshed else {
                            completion(.failure(error)); return
                        }
                        self.load(account: account, token: refreshed.accessToken,
                                  allowRefresh: false, completion: completion)
                    }
                    return
                }
                completion(.failure(error))
            }
        }
    }
}

/// Response parsing, separated from networking so it can be tested against
/// fixtures with no credential and no network.
enum ClaudeUsageParser {

    static func parse(_ obj: [String: Any],
                      account: AIAccount,
                      now: Date = Date(),
                      calendar: Calendar = .current) throws -> AccountUsage {
        var session = limit(obj["five_hour"] as? [String: Any])
        var weeklyAll = limit(obj["seven_day"] as? [String: Any])
        var weeklyScoped = limit(obj["seven_day_sonnet"] as? [String: Any])
            ?? limit(obj["seven_day_opus"] as? [String: Any])
        var scopedName: String = (obj["seven_day_opus"] is [String: Any]) ? "Opus" : "Sonnet"

        // Newer shape: a `limits` array carrying the same windows.
        if let limits = obj["limits"] as? [[String: Any]] {
            for l in limits {
                let kind = l["kind"] as? String
                let parsed = limit(l)
                if kind == "session", session == nil { session = parsed }
                if kind == "weekly_all", weeklyAll == nil { weeklyAll = parsed }
                if kind == "weekly_scoped" {
                    if weeklyScoped == nil { weeklyScoped = parsed }
                    if let scope = l["scope"] as? [String: Any],
                       let model = scope["model"] as? [String: Any],
                       let name = model["display_name"] as? String {
                        scopedName = name
                    }
                }
            }
        }

        // A 200 with no window at all is not a usable update. Reporting it as a
        // parse failure keeps the previous numbers on screen instead of
        // replacing them with a confident 0%.
        guard session != nil || weeklyAll != nil else { throw TransportError.emptyUsage }

        var metrics: [UsageMetric] = []
        if let s = session {
            metrics.append(metric(id: "claude.session", name: "Session",
                                  window: "5-hour", value: s,
                                  account: account, now: now, calendar: calendar,
                                  allowLocalReset: false))
        }
        if let w = weeklyAll {
            metrics.append(metric(id: "claude.weekly_all", name: "Weekly (all)",
                                  window: "7-day", value: w,
                                  account: account, now: now, calendar: calendar,
                                  allowLocalReset: true))
        }
        if let ws = weeklyScoped {
            metrics.append(metric(id: "claude.weekly_scoped", name: "Weekly (\(scopedName))",
                                  window: "7-day", value: ws,
                                  account: account, now: now, calendar: calendar,
                                  allowLocalReset: true))
        }
        if let credit = credit(obj) {
            metrics.append(UsageMetric(
                id: "claude.credits", name: "Extra usage credits",
                usedPercent: Double(credit.percent),
                windowDescription: "monthly",
                detail: "\(Fmt.money(credit.usedMinor, currency: credit.currency, exponent: credit.exponent)) used of "
                      + "\(Fmt.money(credit.limitMinor, currency: credit.currency, exponent: credit.exponent))",
                lastUpdated: now, state: .available))
        }

        let plan = (obj["subscription_type"] as? String) ?? (obj["rate_limit_tier"] as? String)
        return AccountUsage(accountID: account.id,
                            metrics: metrics,
                            accountLabel: plan.map { "plan: \($0)" },
                            fetchedAt: now)
    }

    struct Value { let percent: Double; let resetsAt: Date? }

    static func limit(_ d: [String: Any]?) -> Value? {
        guard let d = d else { return nil }
        guard let pct = (d["percent"] as? NSNumber)?.doubleValue
            ?? (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return Value(percent: pct, resetsAt: parseISODate(d["resets_at"]))
    }

    private static func metric(id: String, name: String, window: String,
                               value: Value, account: AIAccount,
                               now: Date, calendar: Calendar,
                               allowLocalReset: Bool) -> UsageMetric {
        // A local weekly rule describes the weekly window, not the rolling
        // session window — applying it to the session bar would be a lie.
        let overrides = allowLocalReset ? account.resetOverrides
                                        : ResetOverrides(preferProviderReset: true, weekly: nil)
        let resolved = ResetSchedule.resolve(providerReset: value.resetsAt,
                                             overrides: overrides,
                                             now: now, calendar: calendar)
        return UsageMetric(id: id, name: name,
                           usedPercent: value.percent,
                           resetsAt: resolved.date,
                           resetFromProvider: resolved.fromProvider,
                           windowDescription: window,
                           lastUpdated: now,
                           state: .available)
    }

    struct CreditValue {
        let usedMinor: Int, limitMinor: Int, currency: String, exponent: Int, percent: Int
    }

    /// Pay-as-you-go credits. Prefers the newer `spend` block (money in minor
    /// units); falls back to legacy `extra_usage` (whole credits).
    static func credit(_ obj: [String: Any]) -> CreditValue? {
        if let spend = obj["spend"] as? [String: Any] {
            let enabled = (spend["enabled"] as? Bool) ?? true
            if enabled,
               let used = spend["used"] as? [String: Any],
               let limit = spend["limit"] as? [String: Any],
               let usedMinor = (used["amount_minor"] as? NSNumber)?.intValue,
               let limitMinor = (limit["amount_minor"] as? NSNumber)?.intValue,
               limitMinor > 0 {
                let currency = (limit["currency"] as? String) ?? (used["currency"] as? String) ?? "USD"
                let exponent = (limit["exponent"] as? NSNumber)?.intValue
                    ?? (used["exponent"] as? NSNumber)?.intValue ?? 2
                let percent = (spend["percent"] as? NSNumber)?.intValue
                    ?? Int((Double(usedMinor) / Double(limitMinor) * 100).rounded())
                return CreditValue(usedMinor: usedMinor, limitMinor: limitMinor,
                                   currency: currency, exponent: exponent, percent: percent)
            }
        }
        if let ex = obj["extra_usage"] as? [String: Any],
           (ex["is_enabled"] as? Bool) ?? false,
           let limit = (ex["monthly_limit"] as? NSNumber)?.intValue, limit > 0 {
            let used = (ex["used_credits"] as? NSNumber)?.intValue ?? 0
            let currency = (ex["currency"] as? String) ?? "USD"
            let exponent = (ex["decimal_places"] as? NSNumber)?.intValue ?? 2
            let percent = (ex["utilization"] as? NSNumber)?.intValue
                ?? Int((Double(used) / Double(limit) * 100).rounded())
            return CreditValue(usedMinor: used, limitMinor: limit,
                               currency: currency, exponent: exponent, percent: percent)
        }
        return nil
    }
}

private let isoPlain = ISO8601DateFormatter()
private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseISODate(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

/// Parses the OAuth profile response into an account identity. Pure, so the
/// naming rules can be tested against a fixture with no credential.
enum ClaudeIdentityParser {

    static func parse(_ obj: [String: Any],
                      credentials: ClaudeCredentials? = nil,
                      now: Date = Date()) -> AccountIdentity {
        let account = obj["account"] as? [String: Any]
        let organization = obj["organization"] as? [String: Any]

        let email = (account?["email"] as? String) ?? (obj["email_address"] as? String)
        let uuid = (account?["uuid"] as? String) ?? (obj["uuid"] as? String)
        let orgName = organization?["name"] as? String

        // Plan, in order of how directly the provider states it.
        let rawPlan = (organization?["organization_type"] as? String)
            ?? credentials?.subscriptionType
            ?? credentials?.rateLimitTier
        var label = planLabel(rawPlan)
        if label == nil {
            if (account?["has_claude_max"] as? Bool) == true { label = "Max" }
            else if (account?["has_claude_pro"] as? Bool) == true { label = "Pro" }
        }

        return AccountIdentity(email: email,
                               providerAccountID: uuid,
                               organizationName: orgName,
                               planRaw: rawPlan,
                               planLabel: label,
                               verified: email != nil || uuid != nil,
                               detectedAt: now)
    }

    /// Everything we can say when the provider will not name the account.
    static func unidentified(credentials: ClaudeCredentials?, now: Date = Date()) -> AccountIdentity {
        let raw = credentials?.subscriptionType ?? credentials?.rateLimitTier
        return AccountIdentity(planRaw: raw, planLabel: planLabel(raw),
                               verified: false, detectedAt: now)
    }

    /// Friendly plan names, only where the mapping is certain. An identifier we
    /// do not recognise keeps its raw form in diagnostics and contributes no
    /// label, rather than being renamed to something that sounds plausible.
    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "claude_max", "max": return "Max"
        case "claude_pro", "pro": return "Pro"
        case "claude_team", "team": return "Team"
        case "claude_enterprise", "enterprise": return "Enterprise"
        case "claude_free", "free": return "Free"
        default: return nil
        }
    }
}
