// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Umanah. See NOTICE.

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

    func credentialMethods() -> [CredentialMethod] {
        [
            CredentialMethod(
                title: "Import the current Codex/OpenAI account",
                detail: "This app copies that credential into its own Keychain entry, so "
                      + "signing a different account in afterwards does not disturb this one.",
                source: .codexDefault,
                isPrimary: true,
                preflightHeading: "Current ChatGPT app / Codex CLI account",
                disclaimer: "This reads the account stored by Codex/OpenAI tooling on this Mac "
                          + "(~/.codex/auth.json, shared by the ChatGPT desktop app and the Codex "
                          + "CLI). Your ChatGPT browser session may be a different account.",
                switchInstruction: "Switch Codex/OpenAI to the account you want to import "
                                 + "(ChatGPT app or `codex login`), then click Check Again."),
            CredentialMethod(
                title: "Read a credential file instead",
                detail: "Point at another auth.json — useful when you keep a second account's "
                      + "credential somewhere of your own. The file is only ever read, never "
                      + "written.",
                source: .file(path: ""),
                requiresFileChoice: true),
        ]
    }

    /// Identity comes from the credential's own id token, which carries the
    /// e-mail and plan, and is then confirmed against the usage endpoint — that
    /// response names the account and gives a stable account id to deduplicate
    /// on. Local claims alone are enough to proceed if the network is down.
    func discoverIdentity(source: CredentialSource,
                          completion: @escaping (Result<AccountIdentity, AccountError>) -> Void) {
        guard let auth = CodexCredentialStore.read(source: source) else {
            let path = CodexCredentialStore.path(for: source)
                .map { ($0 as NSString).abbreviatingWithTildeInPath }
            completion(.failure(AccountError(
                kind: .missingCredential,
                message: path.map { "No usable credential at \($0)." }
                    ?? "No usable OpenAI credential found there.",
                recovery: "Sign in with the ChatGPT app or run `codex login`, then try again.")))
            return
        }
        guard !auth.isExpired else {
            completion(.failure(AccountError(
                kind: .expiredCredential,
                message: "That credential has expired.",
                recovery: "Open the ChatGPT app or run `codex login` to refresh it, then try again.")))
            return
        }

        let local = OpenAIIdentityParser.fromCredential(auth)
        var headers = ["Authorization": "Bearer \(auth.accessToken)"]
        if let acct = auth.accountId, !acct.isEmpty {
            headers["ChatGPT-Account-Id"] = acct
        }
        HTTP.getJSON(url: OpenAIUsageProvider.usageURL, headers: headers) { result in
            switch result {
            case .success(let obj):
                completion(.success(OpenAIIdentityParser.fromUsage(obj, fallback: local)))
            case .failure(let error):
                let classified = HTTP.classify(error, provider: .openAI)
                if classified.kind == .authenticationFailed {
                    completion(.failure(classified))
                } else {
                    // The credential parsed and named itself; a flaky network is
                    // no reason to block onboarding.
                    completion(.success(local))
                }
            }
        }
    }

    func captureCredential(from source: CredentialSource,
                           forAccountID id: UUID) -> Result<CredentialSource, AccountError> {
        guard CodexCredentialStore.read(source: source) != nil else {
            return .failure(AccountError(kind: .missingCredential,
                                         message: "No usable OpenAI credential found there."))
        }
        guard CodexCredentialStore.capture(from: source, forAccountID: id) else {
            return .failure(AccountError(kind: .unreadableCredential,
                                         message: "Could not save the credential to the Keychain."))
        }
        return .success(.appKeychain(id: id.uuidString))
    }

    /// OpenAI access tokens are short-lived and this app deliberately does not
    /// renew them — renewing would rotate the token the ChatGPT app and Codex
    /// depend on, and signing the user out of those is not a trade worth making.
    ///
    /// So instead: when a captured credential has expired, look at whatever
    /// Codex holds now. If it is a live credential for *the same account id*,
    /// adopt it silently. Signing back in to that account anywhere on this Mac
    /// quietly revives the saved account, with no reconnect step at all. This is
    /// purely local — no network, no token exchange.
    func silentReconnect(for account: AIAccount,
                         completion: @escaping (CredentialSource?) -> Void) {
        guard account.hasCapturedCredential,
              let knownID = account.identity?.providerAccountID,
              let live = CodexCredentialStore.read(source: .codexDefault),
              !live.isExpired,
              let liveID = live.accountId,
              liveID.caseInsensitiveCompare(knownID) == .orderedSame,
              CodexCredentialStore.capture(from: .codexDefault, forAccountID: account.id) else {
            completion(nil); return
        }
        Diagnostics.shared.info("adopted a fresh Codex credential for a matching saved account")
        completion(.appKeychain(id: account.id.uuidString))
    }

    func fetchUsage(for account: AIAccount,
                    completion: @escaping (Result<AccountUsage, Error>) -> Void) {
        let source = account.credentialSource
        // Works for every source: a file another tool owns, or a copy this app
        // captured into its own Keychain entry.
        guard let auth = CodexCredentialStore.read(source: source) else {
            let where_ = CodexCredentialStore.path(for: source)
                .map { " at \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
            completion(.failure(AccountError(
                kind: .missingCredential,
                message: "No usable OpenAI credential\(where_).",
                recovery: "Use Reconnect to sign this account in again.")))
            return
        }
        // We never write auth.json, so an expired token is reported rather than
        // renewed — the tools that own the file refresh it, and the coordinator
        // adopts a matching fresh credential automatically when one appears.
        guard !auth.isExpired else {
            completion(.failure(AccountError(kind: .expiredCredential,
                                             message: "Authentication expired.",
                                             recovery: "Open the ChatGPT app or run `codex login` for this "
                                                     + "account, or use Reconnect.")))
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

    static func planDisplayName(_ raw: String) -> String {
        OpenAIIdentityParser.planLabel(raw) ?? raw.split(separator: "_")
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

/// Turns OpenAI credential claims and usage responses into an account identity.
enum OpenAIIdentityParser {

    /// From the credential alone — works offline, and is what names the account
    /// if the network is unavailable during onboarding.
    static func fromCredential(_ auth: CodexAuth, now: Date = Date()) -> AccountIdentity {
        AccountIdentity(email: auth.email,
                        providerAccountID: auth.accountId,
                        planRaw: auth.planRaw,
                        planLabel: auth.planRaw.flatMap(planLabel),
                        verified: auth.email != nil || auth.accountId != nil,
                        detectedAt: now)
    }

    /// From the usage response, which is the provider speaking directly.
    /// Anything it omits falls back to what the credential said.
    static func fromUsage(_ obj: [String: Any],
                          fallback: AccountIdentity,
                          now: Date = Date()) -> AccountIdentity {
        let email = (obj["email"] as? String) ?? fallback.email
        let accountID = (obj["account_id"] as? String) ?? fallback.providerAccountID
        let raw = (obj["plan_type"] as? String) ?? fallback.planRaw
        return AccountIdentity(email: email,
                               providerAccountID: accountID,
                               planRaw: raw,
                               planLabel: raw.flatMap(planLabel),
                               verified: email != nil || accountID != nil,
                               detectedAt: now)
    }

    /// Friendly plan names, only where the mapping is certain.
    ///
    /// Plan identifiers are internal strings like "self_serve_business_prolite".
    /// The *family* is unambiguous — that is a Business plan — so it maps to
    /// "Business". The "prolite" tier is not something we can name with
    /// confidence, so it is not invented: the raw identifier stays in
    /// diagnostics, and anyone who knows what their plan is called can rename
    /// the account in one click.
    static func planLabel(_ raw: String) -> String? {
        let v = raw.lowercased()
        guard !v.isEmpty else { return nil }
        switch v {
        case "plus", "chatgpt_plus": return "Plus"
        case "pro", "chatgpt_pro": return "Pro"
        case "free", "chatgpt_free": return "Free"
        case "team", "chatgpt_team": return "Team"
        case "enterprise", "chatgpt_enterprise": return "Enterprise"
        case "business", "chatgpt_business": return "Business"
        default: break
        }
        // Compound identifiers: name the family, never the tier.
        for (needle, label) in [("enterprise", "Enterprise"), ("business", "Business"),
                                ("team", "Team"), ("plus", "Plus"), ("pro", "Pro")] {
            if v.contains(needle) { return label }
        }
        return nil
    }
}
