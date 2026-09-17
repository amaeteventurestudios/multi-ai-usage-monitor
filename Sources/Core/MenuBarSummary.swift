import Foundation

/// Builds the menu bar title. Pure, so every mode and every failure combination
/// is covered by tests instead of by squinting at a screenshot.
enum MenuBarSummary {

    struct Entry {
        let badge: String
        let providerName: String
        let usedPercent: Double?
        let hasError: Bool
    }

    static func entries(accounts: [AIAccount],
                        states: [UUID: AccountRuntimeState],
                        store: AccountStore) -> [Entry] {
        accounts.filter { $0.enabled }.map { account in
            let state = states[account.id]
            return Entry(badge: store.badge(for: account),
                         providerName: account.provider.displayName,
                         usedPercent: state?.usage?.headlineMetric?.effectiveUsedPercent,
                         hasError: state?.error != nil)
        }
    }

    /// `nil` means "nothing known yet" and the caller keeps the placeholder.
    static func title(entries: [Entry],
                      mode: MenuBarSummaryMode,
                      showPercentages: Bool = true,
                      showBadges: Bool = true,
                      onlyHighest: Bool = false) -> String? {
        guard !entries.isEmpty else { return nil }

        switch mode {
        case .minimal:
            return entries.contains { $0.hasError } ? "AI !" : "AI"

        case .provider:
            // Worst account per provider, in first-appearance order.
            var order: [String] = []
            var worst: [String: Entry] = [:]
            for e in entries {
                if worst[e.providerName] == nil {
                    order.append(e.providerName)
                    worst[e.providerName] = e
                } else if (e.usedPercent ?? -1) > (worst[e.providerName]?.usedPercent ?? -1) {
                    let keepError = worst[e.providerName]?.hasError ?? false
                    worst[e.providerName] = Entry(badge: e.badge, providerName: e.providerName,
                                                  usedPercent: e.usedPercent,
                                                  hasError: e.hasError || keepError)
                } else if e.hasError, let existing = worst[e.providerName] {
                    worst[e.providerName] = Entry(badge: existing.badge,
                                                  providerName: existing.providerName,
                                                  usedPercent: existing.usedPercent,
                                                  hasError: true)
                }
            }
            let parts = order.compactMap { name -> String? in
                guard let e = worst[name] else { return nil }
                return render(e, label: name, showPercentages: showPercentages)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")

        case .compact:
            var shown = entries
            if onlyHighest {
                // Keep the worst account, but never hide a failure.
                let failing = entries.filter { $0.hasError }
                if let top = entries.max(by: { ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1) }) {
                    shown = failing.contains(where: { $0.badge == top.badge }) ? failing : failing + [top]
                }
                if shown.isEmpty { shown = entries }
            }
            let parts = shown.compactMap {
                render($0, label: showBadges ? $0.badge : $0.providerName,
                       showPercentages: showPercentages)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// One account's fragment. A failing account becomes "C2 !" rather than
    /// turning the whole title into an error.
    private static func render(_ e: Entry, label: String, showPercentages: Bool) -> String? {
        if e.hasError && e.usedPercent == nil { return "\(label) !" }
        guard let p = e.usedPercent else {
            return e.hasError ? "\(label) !" : nil
        }
        let suffix = e.hasError ? " !" : ""
        guard showPercentages else { return "\(label)\(suffix)" }
        return "\(label) \(Int(p.rounded()))%\(suffix)"
    }
}
