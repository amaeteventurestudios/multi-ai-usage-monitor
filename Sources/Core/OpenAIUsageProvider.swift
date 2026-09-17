// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Venture Studios. See NOTICE.

import Foundation

/// OpenAI usage, read from the Codex usage endpoint using the credential the
/// Codex CLI and the ChatGPT desktop app share.
///
/// What this endpoint actually reports is *Codex* usage — the rolling and
/// weekly windows that govern Codex requests — which is why the metrics are
/// named "Codex …" rather than a generic "ChatGPT". ChatGPT chat-message
/// allowances are a different quota and this credential cannot read them; see
/// `proMessagesPlaceholder` and docs/KNOWN_LIMITATIONS.md.
final class OpenAIUsageProvider: UsageProvider {
    let providerKind: ProviderKind = .openAI

    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    func credentialStatus(for account: AIAccount) -> CredentialStatus {
        CodexCredentialStore.status(of: account.credentialSource)
    }

    func suggestedDisplayName(for source: CredentialSource) -> String? {
        let hint = CodexCredentialStore.identityHint(source: source)
        if let plan = hint.plan, !plan.isEmpty {
            return "OpenAI (\(OpenAIUsageParser.planDisplayName(plan)))"
        }
        return nil
    }

    func fetchUsage(for account: AIAccount,
                    completion: @escaping (Result<AccountUsage, Error>) -> Void) {
        let source = account.credentialSource
        guard let path = CodexCredentialStore.path(for: source) else {
            completion(.failure(AccountError(kind: .invalidPath,
                                             message: "This account has no OpenAI credential file configured.",
                                             recovery: "Choose a credential source in Settings.")))
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            completion(.failure(AccountError(
                kind: .missingCredential,
                message: "No credential file at \((path as NSString).abbreviatingWithTildeInPath).",
                recovery: "Sign in with the ChatGPT app or `codex`, or point this account at another auth.json.")))
            return
        }
        guard let auth = CodexCredentialStore.read(source: source) else {
            completion(.failure(AccountError(kind: .parsing,
                                             message: "The credential file has no readable access token.",
                                             recovery: "Sign in again with the ChatGPT app or `codex`.")))
            return
        }
        // We never write auth.json, so an expired token is reported rather than
        // renewed — the tools that own the file refresh it, and the next poll
        // picks it up.
        guard !auth.isExpired else {
            completion(.failure(AccountError(kind: .expiredCredential,
                                             message: "Authentication expired.",
                                             recovery: "Open ChatGPT or run `codex` to sign in again, then Refresh.")))
            return
        }

        var headers = ["Authorization": "Bearer \(auth.accessToken)"]
        if let acct = auth.accountId, !acct.isEmpty {
            headers["ChatGPT-Account-Id"] = acct
        }
        HTTP.getJSON(url: OpenAIUsageProvider.usageURL, headers: headers) { result in
            switch result {
            case .success(let obj):
                do { completion(.success(try OpenAIUsageParser.parse(obj, account: account))) }
                catch { completion(.failure(error)) }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

enum OpenAIUsageParser {

    /// Plan identifiers are internal strings ("self_serve_business_prolite").
    /// Turn them into something readable without pretending to know plans we
    /// have not seen — unknown values are title-cased, not renamed.
    static func planDisplayName(_ raw: String) -> String {
        let known: [String: String] = [
            "plus": "Plus",
            "pro": "Pro",
            "free": "Free",
            "team": "Team",
            "enterprise": "Enterprise",
            "business": "Business",
        ]
        if let k = known[raw.lowercased()] { return k }
        return raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func parse(_ obj: [String: Any],
                      account: AIAccount,
                      now: Date = Date(),
                      calendar: Calendar = .current) throws -> AccountUsage {
        let rl = obj["rate_limit"] as? [String: Any]
        var metrics: [UsageMetric] = []

        if let m = window(rl?["primary_window"] as? [String: Any], idSuffix: "primary",
                          account: account, now: now, calendar: calendar) {
            metrics.append(m)
        }
        if let m = window(rl?["secondary_window"] as? [String: Any], idSuffix: "secondary",
                          account: account, now: now, calendar: calendar) {
            metrics.append(m)
        }
        if let m = window(obj["code_review_rate_limit"] as? [String: Any], idSuffix: "code_review",
                          nameOverride: "Codex code review",
                          account: account, now: now, calendar: calendar) {
            metrics.append(m)
        }
        // Any additional windows the provider starts returning show up without a
        // code change, named from the window length the provider reports.
        if let extra = obj["additional_rate_limits"] as? [[String: Any]] {
            for (i, d) in extra.enumerated() {
                if let m = window(d, idSuffix: "extra\(i)", account: account, now: now, calendar: calendar) {
                    metrics.append(m)
                }
            }
        }

        // A 200 with no window at all is not a usable update.
        guard !metrics.isEmpty else { throw TransportError.emptyUsage }

        metrics.append(proMessagesPlaceholder(now: now))

        var notes: [String] = []
        if let note = creditNote(obj) { notes.append(note) }
        if let unavailable = modelAvailabilityNote(obj) { notes.append(unavailable) }

        let email = obj["email"] as? String
        let plan = (obj["plan_type"] as? String).map(planDisplayName)
        let label = [email, plan.map { "plan: \($0)" }].compactMap { $0 }.joined(separator: " · ")

        return AccountUsage(accountID: account.id,
                            metrics: metrics,
                            accountLabel: label.isEmpty ? nil : label,
                            notes: notes,
                            fetchedAt: now)
    }

    /// ChatGPT's own message allowance (the "x of y Pro messages" a paid
    /// ChatGPT plan grants) is governed by a different quota than Codex usage,
    /// and the Codex credential is not authorised for the endpoints that report
    /// it — they answer HTTP 403. Rather than count messages this app cannot
    /// see (the user also sends them from the web and desktop clients), the
    /// metric exists in an honest `unsupported` state, ready to carry real
    /// numbers the day a readable source exists.
    static func proMessagesPlaceholder(now: Date) -> UsageMetric {
        UsageMetric(id: "openai.pro_messages",
                    name: "ChatGPT messages",
                    detail: "Not detectable yet — this credential only exposes Codex usage.",
                    lastUpdated: now,
                    state: .unsupported)
    }

    static func window(_ d: [String: Any]?,
                       idSuffix: String,
                       nameOverride: String? = nil,
                       account: AIAccount,
                       now: Date,
                       calendar: Calendar) -> UsageMetric? {
        guard let d = d,
              let pct = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }

        var providerReset: Date?
        if let at = (d["reset_at"] as? NSNumber)?.doubleValue, at > 0 {
            providerReset = Date(timeIntervalSince1970: at)
        } else if let after = (d["reset_after_seconds"] as? NSNumber)?.doubleValue {
            providerReset = now.addingTimeInterval(after)
        }

        let secs = (d["limit_window_seconds"] as? NSNumber)?.intValue ?? -1
        let windowName = Fmt.windowLabel(secs)
        // Name from the window the provider reports, never a hard-coded "5-hour".
        let name = nameOverride ?? "Codex \(windowName)"

        // OpenAI always supplies a reset for these windows, so a local weekly
        // rule is only ever a fallback here.
        let resolved = ResetSchedule.resolve(providerReset: providerReset,
                                             overrides: ResetOverrides(preferProviderReset: true,
                                                                       weekly: account.resetOverrides.weekly),
                                             now: now, calendar: calendar)
        return UsageMetric(id: "openai.\(idSuffix)",
                           name: name,
                           usedPercent: pct,
                           resetsAt: resolved.date,
                           resetFromProvider: resolved.fromProvider,
                           windowDescription: windowName,
                           lastUpdated: now,
                           state: .available)
    }

    /// A credit balance with no cap cannot be drawn as a percentage, so it is a
    /// plain line instead of a bar.
    static func creditNote(_ obj: [String: Any]) -> String? {
        guard let c = obj["credits"] as? [String: Any] else { return nil }
        if (c["unlimited"] as? Bool) == true { return "Credits: unlimited" }
        guard (c["has_credits"] as? Bool) == true,
              let balance = (c["balance"] as? NSNumber)?.doubleValue else { return nil }
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 2
        return "Credits: \(f.string(from: NSNumber(value: balance)) ?? "\(balance)") remaining"
    }

    /// Report models the provider says are currently unavailable to this
    /// account — real information, straight from the response.
    static func modelAvailabilityNote(_ obj: [String: Any]) -> String? {
        guard let usage = obj["model_usage"] as? [String: Any] else { return nil }
        let unavailable = usage.compactMap { (name, value) -> String? in
            guard let d = value as? [String: Any],
                  (d["available"] as? Bool) == false else { return nil }
            return name
        }.sorted()
        guard !unavailable.isEmpty else { return nil }
        return "Unavailable now: \(unavailable.joined(separator: ", "))"
    }
}
