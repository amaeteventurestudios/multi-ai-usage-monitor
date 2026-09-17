// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Venture Studios. See NOTICE.

import Foundation

/// Claude (Anthropic) usage, read from the OAuth usage endpoint using the
/// credential Claude Code already holds.
final class ClaudeUsageProvider: UsageProvider {
    let providerKind: ProviderKind = .claude

    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
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

    func suggestedDisplayName(for source: CredentialSource) -> String? {
        guard let creds = ClaudeCredentialStore.read(source: source) else { return nil }
        // The credential records a plan, not an identity — the usage endpoint
        // does not name the account either. A plan is a better starting label
        // than nothing, and the user can rename it.
        if let plan = creds.subscriptionType ?? creds.rateLimitTier, !plan.isEmpty {
            return "Claude (\(plan))"
        }
        return nil
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
