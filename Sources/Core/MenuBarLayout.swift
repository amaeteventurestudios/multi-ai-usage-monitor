import Foundation

/// How each account's usage is drawn in the menu bar.
enum UsageDisplayMode: String, CaseIterable, Codable {
    /// One bar per window: five-hour and weekly, stacked.
    case dualBars
    /// A single bar for the worse of the two windows.
    case singleSummaryBar
    /// No bars at all.
    case textOnly

    var displayName: String {
        switch self {
        case .dualBars:         return "Dual Bars"
        case .singleSummaryBar: return "Single Summary Bar"
        case .textOnly:         return "Text Only"
        }
    }

    var explanation: String {
        switch self {
        case .dualBars:
            return "Shows five-hour and weekly usage separately, each with its own colour. "
                 + "Best for seeing which window is the constrained one."
        case .singleSummaryBar:
            return "One bar per account, showing whichever window is further used."
        case .textOnly:
            return "Percentages with no bars. The narrowest option."
        }
    }
}

/// How long a mini bar is. Widths are in points, chosen so the three options
/// are visibly different without any of them being unreadable.
enum MiniBarLength: String, CaseIterable, Codable {
    case short, medium, long

    var displayName: String {
        switch self {
        case .short:  return "Short"
        case .medium: return "Medium"
        case .long:   return "Long"
        }
    }

    /// Bar width in points.
    var width: Double {
        switch self {
        case .short:  return 22
        case .medium: return 40
        case .long:   return 58
        }
    }

    /// Number of cells a text-drawn bar uses, for the same shape without
    /// custom drawing.
    var cellCount: Int {
        switch self {
        case .short:  return 4
        case .medium: return 8
        case .long:   return 12
        }
    }
}

/// One usage window as the menu bar will draw it.
struct MenuBarWindowRow: Equatable {
    let role: UsageWindowRole
    /// Used percent, or nil when there is nothing to show yet.
    let percent: Double?
    let hasError: Bool
    let isStale: Bool

    var severity: UsageSeverity? {
        guard let p = percent, !hasError else { return nil }
        return UsageSeverity.forUsedPercent(p)
    }

    /// "57%", "--%" or "!".
    var valueText: String {
        if hasError { return "!" }
        guard let p = percent else { return "--%" }
        return "\(Int(p.rounded()))%"
    }

    /// The bar's fill, 0...1. A window with no value draws an empty track
    /// rather than nothing, so the row keeps its shape.
    var fill: Double {
        guard let p = percent, !hasError else { return 0 }
        return min(1, max(0, p / 100))
    }
}

/// One account, laid out. The renderer draws this; the settings preview draws
/// the same thing from the same model, so a preview can never disagree with
/// what the menu bar actually shows.
struct MenuBarCell: Equatable {
    let label: String
    let rows: [MenuBarWindowRow]
    /// Everything this cell says, in words, for VoiceOver.
    let accessibilityText: String
}

/// Builds the menu bar's contents. Pure: every combination of summary mode,
/// label format, usage display and bar length is testable without a screen.
enum MenuBarLayout {

    /// What one account contributes, before formatting.
    struct Source: Equatable {
        let badge: String
        let providerName: String
        let shortName: String
        let fiveHour: MenuBarWindowRow?
        let weekly: MenuBarWindowRow?
        /// An account-level failure, e.g. a credential that needs reconnecting.
        let hasAccountError: Bool

        /// The worse of the two windows — never their sum, which would mean
        /// nothing.
        var summaryPercent: Double? {
            let values = [fiveHour?.percent, weekly?.percent].compactMap { $0 }
            return values.max()
        }

        var anyError: Bool {
            hasAccountError || (fiveHour?.hasError ?? false) || (weekly?.hasError ?? false)
        }

        var anyStale: Bool { (fiveHour?.isStale ?? false) || (weekly?.isStale ?? false) }
    }

    static func sources(accounts: [AIAccount],
                        states: [UUID: AccountRuntimeState],
                        now: Date = Date()) -> [Source] {
        accounts.filter { $0.enabled }.map { account in
            let state = states[account.id]
            let metrics = state?.usage.map {
                UsageCoordinator.applyStaleness(to: $0.metrics, fetchedAt: $0.fetchedAt,
                                                hasError: state?.error != nil, now: now)
            } ?? []

            func row(_ role: UsageWindowRole) -> MenuBarWindowRow? {
                guard let metric = metrics.first(where: { $0.role == role }) else {
                    // No metric at all: only worth a row if the account itself
                    // is in trouble, so the failure is visible rather than blank.
                    return state?.error == nil ? nil
                        : MenuBarWindowRow(role: role, percent: nil, hasError: true, isStale: false)
                }
                let unusable = metric.state == .unsupported
                    || metric.state == .authenticationRequired
                    || metric.state == .error
                return MenuBarWindowRow(role: role,
                                        percent: metric.effectiveUsedPercent,
                                        hasError: unusable || (metric.effectiveUsedPercent == nil
                                                               && state?.error != nil),
                                        isStale: metric.state == .stale)
            }

            return Source(badge: account.provider.badgeLetter,
                          providerName: account.provider.displayName,
                          shortName: account.shortDisplayName,
                          fiveHour: row(.fiveHour),
                          weekly: row(.weekly),
                          hasAccountError: state?.error != nil)
        }
    }

    /// Collapse per-account sources into one per provider, taking the worst
    /// value for *each window separately* — so a provider's five-hour figure
    /// and its weekly figure may come from different accounts. That is the
    /// honest answer to "how constrained is this provider right now".
    static func byProvider(_ sources: [Source]) -> [Source] {
        var order: [String] = []
        var grouped: [String: [Source]] = [:]
        for s in sources {
            if grouped[s.providerName] == nil { order.append(s.providerName) }
            grouped[s.providerName, default: []].append(s)
        }
        return order.compactMap { name in
            guard let group = grouped[name], let first = group.first else { return nil }
            func worst(_ pick: (Source) -> MenuBarWindowRow?) -> MenuBarWindowRow? {
                let rows = group.compactMap(pick)
                guard !rows.isEmpty else { return nil }
                let best = rows.max { ($0.percent ?? -1) < ($1.percent ?? -1) }
                return MenuBarWindowRow(role: best?.role ?? .other,
                                        percent: best?.percent,
                                        hasError: rows.contains { $0.hasError },
                                        isStale: rows.contains { $0.isStale })
            }
            return Source(badge: first.badge,
                          providerName: name,
                          shortName: name,
                          fiveHour: worst { $0.fiveHour },
                          weekly: worst { $0.weekly },
                          hasAccountError: group.contains { $0.hasAccountError })
        }
    }

    /// The cells to draw, or an empty array when there is nothing to say.
    static func cells(sources: [Source],
                      mode: MenuBarSummaryMode,
                      format: PerAccountFormat,
                      usageDisplay: UsageDisplayMode,
                      showPercentages: Bool = true,
                      onlyHighest: Bool = false) -> [MenuBarCell] {
        guard mode != .iconOnly, !sources.isEmpty else { return [] }

        let shown = shownSources(sources, mode: mode, onlyHighest: onlyHighest)
        let labels = mode == .provider
            ? shown.map { $0.providerName }
            : accountLabels(for: shown, format: format)

        return zip(shown, labels).map { source, label in
            let rows: [MenuBarWindowRow]
            switch usageDisplay {
            case .dualBars:
                rows = [source.fiveHour, source.weekly].compactMap { $0 }
            case .singleSummaryBar:
                // Nothing known and nothing wrong means nothing to draw: an
                // account that has simply not been fetched yet should not
                // occupy the menu bar with an empty bar.
                rows = (source.summaryPercent == nil && !source.anyError) ? []
                    : [MenuBarWindowRow(role: .other,
                                        percent: source.summaryPercent,
                                        hasError: source.anyError && source.summaryPercent == nil,
                                        isStale: source.anyStale)]
            case .textOnly:
                rows = []
            }
            return MenuBarCell(label: label,
                               rows: rows,
                               accessibilityText: accessibilityText(source, label: label,
                                                                    usageDisplay: usageDisplay))
        }
    }

    /// Menu bar text for the modes that are text rather than drawing.
    static func textTitle(sources: [Source],
                          mode: MenuBarSummaryMode,
                          format: PerAccountFormat,
                          usageDisplay: UsageDisplayMode,
                          showPercentages: Bool = true,
                          onlyHighest: Bool = false) -> String? {
        if mode == .iconOnly {
            return sources.contains { $0.anyError } ? "AI !" : "AI"
        }
        let shown = shownSources(sources, mode: mode, onlyHighest: onlyHighest)
        let labels = mode == .provider
            ? shown.map { $0.providerName }
            : accountLabels(for: shown, format: format)

        let parts: [String] = zip(shown, labels).compactMap { source, label in
            let rows: [MenuBarWindowRow]
            let values: [String]

            switch usageDisplay {
            case .textOnly, .dualBars:
                rows = [source.fiveHour, source.weekly].compactMap { $0 }
                values = rows.map { showPercentages ? "\($0.role.shortTag)\($0.valueText)"
                                                    : $0.role.shortTag }
            case .singleSummaryBar:
                guard let percent = source.summaryPercent else {
                    rows = []; values = []; break
                }
                rows = [MenuBarWindowRow(role: .other, percent: percent,
                                         hasError: false, isStale: source.anyStale)]
                values = showPercentages ? ["\(Int(percent.rounded()))%"] : []
            }

            // Nothing known and nothing wrong: contribute nothing, rather than
            // occupying the menu bar with an empty label.
            guard !rows.isEmpty else { return source.anyError ? "\(label) !" : nil }

            // A retained number keeps its place *and* gets flagged, so a stale
            // or failing account is never mistaken for a healthy one — and never
            // silently dropped either. The flag is redundant when every window
            // is already showing its own "!".
            let everyWindowFailed = rows.allSatisfy { $0.hasError }
            let flag = (source.anyError && !everyWindowFailed) ? " !" : ""
            guard !values.isEmpty else { return "\(label)\(flag)" }
            return "\(label) \(values.joined(separator: " "))\(flag)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The sources a mode actually shows, after grouping and any filtering.
    private static func shownSources(_ sources: [Source],
                                     mode: MenuBarSummaryMode,
                                     onlyHighest: Bool) -> [Source] {
        var shown = mode == .provider ? byProvider(sources) : sources
        if mode == .perAccount, onlyHighest {
            let failing = shown.filter { $0.anyError }
            if let top = shown.max(by: { ($0.summaryPercent ?? -1) < ($1.summaryPercent ?? -1) }) {
                shown = failing.contains(where: { $0.shortName == top.shortName })
                    ? failing : failing + [top]
            }
            if shown.isEmpty { shown = sources }
        }
        return shown
    }

    /// The leading label for each account, in the chosen format. Account order
    /// is preserved exactly — the menu bar is read positionally, so reordering
    /// it by usage would make it harder to scan, not easier.
    static func accountLabels(for sources: [Source], format: PerAccountFormat) -> [String] {
        let names = sources.map { $0.shortName }
        switch format {
        case .detailed:
            return sources.map { "\($0.badge) \($0.shortName)" }
        case .compact:
            let abbreviations = ShortName.uniqueAbbreviations(names, groups: sources.map { $0.badge })
            return zip(sources, abbreviations).map { "\($0.badge)-\($1)" }
        case .minimalLabels:
            return ShortName.uniqueAbbreviations(names, groups: sources.map { _ in "" })
        }
    }

    /// Colour is never the only signal: everything a cell shows is also said in
    /// words.
    static func accessibilityText(_ source: Source, label: String,
                                  usageDisplay: UsageDisplayMode) -> String {
        var parts: [String] = [source.shortName]
        func describe(_ row: MenuBarWindowRow?) {
            guard let row = row else { return }
            if row.hasError {
                parts.append("\(row.role.spokenName) unavailable")
            } else if let p = row.percent {
                let severity = UsageSeverity.forUsedPercent(p)
                parts.append("\(row.role.spokenName), \(Int(p.rounded())) percent used, "
                           + severity.accessibilityWord + (row.isStale ? ", stale" : ""))
            } else {
                parts.append("\(row.role.spokenName) not known yet")
            }
        }
        switch usageDisplay {
        case .dualBars, .textOnly:
            describe(source.fiveHour)
            describe(source.weekly)
        case .singleSummaryBar:
            if let p = source.summaryPercent {
                parts.append("highest usage \(Int(p.rounded())) percent used")
            } else {
                parts.append("usage not known yet")
            }
        }
        if source.hasAccountError { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
