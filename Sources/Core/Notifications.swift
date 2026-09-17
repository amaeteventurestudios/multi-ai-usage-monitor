import Foundation

/// A notification the app has decided to show.
struct PendingAlert: Equatable {
    let title: String
    let body: String
    let key: String
}

/// Decides when a usage warning should fire, and — just as importantly — when
/// it should not.
///
/// State is keyed by account, metric, threshold and usage window, so:
///   * the same warning never repeats inside one window;
///   * two accounts on the same provider never suppress each other;
///   * a new window automatically re-arms the warning after a reset.
///
/// Pure and injectable, so the dedup rules are tested rather than hoped for.
final class NotificationTracker {
    /// key → the reset date of the window we last alerted for.
    private var alerted: [String: Date] = [:]
    private let d: UserDefaults?
    private let storageKey = "notifications.state.v1"

    init(defaults: UserDefaults? = nil) {
        self.d = defaults
        load()
    }

    private func load() {
        guard let d = d, let data = d.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        alerted = decoded
    }

    private func save() {
        guard let d = d, let data = try? JSONEncoder().encode(alerted) else { return }
        d.set(data, forKey: storageKey)
    }

    func reset() {
        alerted = [:]
        save()
    }

    private func key(account: AIAccount, metric: UsageMetric, threshold: Int) -> String {
        "\(account.id.uuidString)|\(metric.id)|\(threshold)"
    }

    /// The window a metric currently belongs to. A metric with no known reset
    /// gets `distantFuture`, which means "one window forever" — it will alert
    /// once and stay quiet, which is the right behaviour when we cannot tell
    /// windows apart.
    private func windowKey(_ metric: UsageMetric) -> Date { metric.resetsAt ?? .distantFuture }

    /// Usage warnings for one account's metrics. Returns only alerts that
    /// should actually be posted; calling it again with the same data returns
    /// nothing.
    func usageAlerts(for account: AIAccount,
                     usage: AccountUsage,
                     settings: AppSettings) -> [PendingAlert] {
        guard settings.usageWarningsEnabled else { return [] }
        let threshold = account.notificationThresholdPercent ?? settings.warningThresholdPercent
        var out: [PendingAlert] = []

        for metric in usage.metrics {
            guard metric.state == .available else { continue }
            let k = key(account: account, metric: metric, threshold: threshold)
            let window = windowKey(metric)

            guard let used = metric.effectiveUsedPercent else { continue }
            guard used >= Double(threshold) else {
                // Dropped back below the line: forget this window so a later
                // crossing can fire again.
                if alerted[k] == window { alerted[k] = nil; save() }
                continue
            }
            if alerted[k] == window { continue }   // already warned in this window
            alerted[k] = window
            save()

            let resetPart: String
            if let line = Fmt.absoluteReset(metric.resetsAt) {
                resetPart = " Resets \(line)."
            } else {
                resetPart = ""
            }
            // A count-based metric says how many are left; a percentage one
            // says the percentage. Never both, never invented.
            let body: String
            if let remaining = metric.remainingCount, metric.limitCount != nil {
                body = "Only \(remaining) left of \(metric.limitCount!).\(resetPart)"
            } else {
                body = "\(metric.name) usage has reached \(Int(used.rounded()))%.\(resetPart)"
            }
            out.append(PendingAlert(title: "\(account.displayName) — \(account.provider.displayName)",
                                    body: body, key: k))
        }
        return out
    }

    /// One alert per account when its credential stops working, re-armed only
    /// after the account recovers.
    func authAlert(for account: AIAccount,
                   error: AccountError?,
                   settings: AppSettings) -> PendingAlert? {
        let k = "\(account.id.uuidString)|auth"
        guard settings.authWarningsEnabled else { return nil }
        guard let error = error,
              error.kind == .expiredCredential || error.kind == .authenticationFailed
                || error.kind == .missingCredential else {
            if alerted[k] != nil { alerted[k] = nil; save() }
            return nil
        }
        if alerted[k] != nil { return nil }
        alerted[k] = .distantFuture
        save()
        return PendingAlert(title: "\(account.displayName) — attention needed",
                            body: [error.message, error.recovery].compactMap { $0 }.joined(separator: " "),
                            key: k)
    }
}

/// Posts a local notification.
///
/// `osascript` rather than `UNUserNotificationCenter`: the latter requires a
/// signed bundle with a registered identifier to deliver anything, and this app
/// is built and run locally unsigned. See docs/DECISIONS.md.
enum NotificationPoster {
    static func post(_ alert: PendingAlert) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(alert.body))\" with title \"\(esc(alert.title))\""
        _ = runProcess("/usr/bin/osascript", ["-e", script])
    }
}
