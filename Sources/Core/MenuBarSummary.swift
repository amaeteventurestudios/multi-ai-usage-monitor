import Foundation

/// Builds the menu bar title. Pure, so every mode, format and failure
/// combination is covered by tests instead of by squinting at a screenshot.
enum MenuBarSummary {

    struct Entry {
        /// Provider initial, e.g. "C" or "G".
        let badge: String
        let providerName: String
        /// The account's menu bar alias.
        let shortName: String
        let usedPercent: Double?
        let hasError: Bool
    }

    static func entries(accounts: [AIAccount],
                        states: [UUID: AccountRuntimeState]) -> [Entry] {
        accounts.filter { $0.enabled }.map { account in
            let state = states[account.id]
            return Entry(badge: account.provider.badgeLetter,
                         providerName: account.provider.displayName,
                         shortName: account.shortDisplayName,
                         usedPercent: state?.usage?.headlineMetric?.effectiveUsedPercent,
                         hasError: state?.error != nil)
        }
    }

    /// `nil` means "nothing known yet" and the caller keeps its placeholder.
    static func title(entries: [Entry],
                      mode: MenuBarSummaryMode,
                      format: PerAccountFormat = .detailed,
                      showPercentages: Bool = true,
                      onlyHighest: Bool = false) -> String? {
        guard !entries.isEmpty else { return nil }

        switch mode {
        case .iconOnly:
            return entries.contains { $0.hasError } ? "AI !" : "AI"

        case .provider:
            return providerTitle(entries, showPercentages: showPercentages)

        case .perAccount:
            var shown = entries
            if onlyHighest {
                // Keep the worst account, but never hide a failure.
                let failing = entries.filter { $0.hasError }
                if let top = entries.max(by: { ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1) }),
                   !failing.contains(where: { $0.shortName == top.shortName }) {
                    shown = failing + [top]
                } else if !failing.isEmpty {
                    shown = failing
                }
                if shown.isEmpty { shown = entries }
            }
            let labels = accountLabels(for: shown, format: format)
            let parts = zip(shown, labels).compactMap { entry, label -> String? in
                render(entry, label: label, showPercentages: showPercentages)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// The leading label for each account, in the chosen format. Account order
    /// is preserved exactly — the menu bar is read positionally, so reordering
    /// it by usage would make it harder to scan, not easier.
    static func accountLabels(for entries: [Entry], format: PerAccountFormat) -> [String] {
        let names = entries.map { $0.shortName }
        switch format {
        case .detailed:
            // Provider initial plus the full alias: "C Amaete".
            return entries.map { "\($0.badge) \($0.shortName)" }

        case .compact:
            // "C-A". The provider initial is part of the label, so aliases only
            // need to be unambiguous within their own provider.
            let abbreviations = ShortName.uniqueAbbreviations(names, groups: entries.map { $0.badge })
            return zip(entries, abbreviations).map { "\($0.badge)-\($1)" }

        case .minimalLabels:
            // "A". Nothing else distinguishes these, so every alias competes
            // with every other one.
            return ShortName.uniqueAbbreviations(names, groups: entries.map { _ in "" })
        }
    }

    private static func providerTitle(_ entries: [Entry], showPercentages: Bool) -> String? {
        var order: [String] = []
        var worst: [String: Entry] = [:]
        for e in entries {
            guard let existing = worst[e.providerName] else {
                order.append(e.providerName)
                worst[e.providerName] = e
                continue
            }
            let takeNew = (e.usedPercent ?? -1) > (existing.usedPercent ?? -1)
            let base = takeNew ? e : existing
            worst[e.providerName] = Entry(badge: base.badge,
                                          providerName: base.providerName,
                                          shortName: base.shortName,
                                          usedPercent: base.usedPercent,
                                          hasError: existing.hasError || e.hasError)
        }
        let parts = order.compactMap { name -> String? in
            guard let e = worst[name] else { return nil }
            return render(e, label: name, showPercentages: showPercentages)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One account's fragment.
    ///
    /// A failing account becomes "C StarLogic !" rather than disappearing or
    /// turning the whole title into an error: an account you cannot see is an
    /// account you forget you were relying on. The dropdown carries the reason.
    private static func render(_ e: Entry, label: String, showPercentages: Bool) -> String? {
        if e.hasError { return "\(label) !" }
        guard let p = e.usedPercent else { return nil }
        guard showPercentages else { return label }
        return "\(label) \(Int(p.rounded()))%"
    }
}
