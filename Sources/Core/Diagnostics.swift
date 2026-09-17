import Foundation

/// Structured, local-only logging.
///
/// Nothing here leaves the machine. Debug is off by default, and every message
/// passes through `Redact` on the way in, so a careless call site still cannot
/// put a token in the buffer.
enum LogLevel: Int, Comparable {
    case debug = 0, info, warning, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// Strips anything that looks like a secret or a personal identifier out of a
/// string before it reaches the log buffer or the clipboard.
enum Redact {
    /// Long opaque runs (JWTs, OAuth tokens, API keys) and anything after a
    /// token-ish key name.
    private static let patterns: [(NSRegularExpression, String)] = {
        func re(_ p: String) -> NSRegularExpression {
            // Force-try is safe: these literals are fixed and compile-time correct.
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            (re("(eyJ[A-Za-z0-9_\\-]{5,}\\.[A-Za-z0-9_\\-]{5,}\\.[A-Za-z0-9_\\-]*)"), "<jwt-redacted>"),
            (re("(sk-[A-Za-z0-9_\\-]{8,})"), "<key-redacted>"),
            (re("(bearer\\s+)[A-Za-z0-9._\\-]+"), "$1<redacted>"),
            (re("((?:access|refresh|id)_token\"?\\s*[:=]\\s*\"?)[^\",\\s}]+"), "$1<redacted>"),
            (re("(authorization\"?\\s*[:=]\\s*\"?)[^\",\\s}]+"), "$1<redacted>"),
            (re("(cookie\"?\\s*[:=]\\s*\"?)[^\",\\s}]+"), "$1<redacted>"),
        ]
    }()

    static func secrets(_ s: String) -> String {
        var out = s
        for (regex, template) in patterns {
            out = regex.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: template)
        }
        return out
    }

    /// Replace the local account name in absolute paths, so a diagnostic dump
    /// pasted into a public issue does not reveal the user's home directory.
    static func homePaths(_ s: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return s }
        return s.replacingOccurrences(of: home, with: "~")
                .replacingOccurrences(of: "/Users/\(NSUserName())", with: "/Users/<user>")
    }

    /// user@example.com → u***@example.com. Applied to diagnostics unless the
    /// user opts in to including identities.
    static func email(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*(@[A-Za-z0-9.-]+\\.[A-Za-z]{2,})") else { return s }
        return regex.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "$1***$2")
    }

    /// Everything, for anything that might be shared.
    static func all(_ s: String) -> String { email(homePaths(secrets(s))) }
}

/// A bounded in-memory log plus an optional on-disk copy under
/// ~/Library/Logs. Bounded so a long-running menu bar app cannot grow without
/// limit.
final class Diagnostics {
    static let shared = Diagnostics()

    private let queue = DispatchQueue(label: "diagnostics")
    private var buffer: [String] = []
    private let capacity = 500
    private let dateFormatter: DateFormatter

    /// Raised to `.debug` by the Advanced settings toggle.
    var minimumLevel: LogLevel = .info

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    static var logFileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return dir.appendingPathComponent("MultiAIUsageMonitor.log")
    }

    func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel else { return }
        let line = "\(dateFormatter.string(from: Date())) [\(level.label)] \(Redact.secrets(message()))"
        queue.async {
            self.buffer.append(line)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
        }
    }

    func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    func info(_ m: @autoclosure () -> String) { log(.info, m()) }
    func warning(_ m: @autoclosure () -> String) { log(.warning, m()) }
    func error(_ m: @autoclosure () -> String) { log(.error, m()) }

    func recentLines() -> [String] { queue.sync { buffer } }

    /// Write the buffer to ~/Library/Logs so "Open Logs" has something to open.
    @discardableResult
    func flushToDisk() -> URL? {
        let url = Diagnostics.logFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let text = recentLines().joined(separator: "\n") + "\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
}

/// The "Copy Diagnostics" payload: enough for a useful bug report, and nothing
/// that could authenticate anybody.
enum DiagnosticsReport {
    static func build(accounts: [AIAccount],
                      states: [UUID: AccountRuntimeState],
                      credentialStatus: [UUID: CredentialStatus],
                      settings: AppSettings,
                      includeIdentities: Bool,
                      now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("\(AppInfo.name) \(AppInfo.version)")
        lines.append("macOS \(AppInfo.osVersionString) · \(AppInfo.architecture)")
        lines.append("Generated \(ISO8601DateFormatter().string(from: now))")
        lines.append("")
        lines.append("Settings")
        lines.append("  schema version: \(settings.schemaVersion)")
        lines.append("  refresh: \(settings.refreshIntervalMinutes.map { "\($0) min" } ?? "manual")")
        lines.append("  menu bar summary: \(settings.menuBarSummaryMode.rawValue)")
        lines.append("  usage warnings: \(settings.usageWarningsEnabled) at \(settings.warningThresholdPercent)%")
        lines.append("  auth warnings: \(settings.authWarningsEnabled)")
        lines.append("")
        lines.append("Accounts (\(accounts.count))")
        for a in accounts.sorted(by: { $0.order < $1.order }) {
            lines.append("  [\(a.provider.rawValue)] \(a.displayName)")
            lines.append("    enabled: \(a.enabled)")
            lines.append("    credential source: \(a.credentialSource.kindLabel)")
            lines.append("    credential status: \(credentialStatus[a.id]?.displayName ?? "unknown")")
            if let w = a.resetOverrides.weekly {
                lines.append("    local reset rule: \(w.weekdayName) \(String(format: "%02d:%02d", w.hour, w.minute))")
            }
            lines.append("    prefers provider reset: \(a.resetOverrides.preferProviderReset)")
            let state = states[a.id]
            if let s = state?.lastSuccess {
                lines.append("    last success: \(Int(now.timeIntervalSince(s)))s ago")
            } else {
                lines.append("    last success: never")
            }
            if let e = state?.error {
                lines.append("    error: \(e.kind.rawValue) — \(e.message)")
            }
            if let label = state?.usage?.accountLabel {
                lines.append("    provider says: \(label)")
            }
            for m in state?.usage?.metrics ?? [] {
                let value = m.effectiveUsedPercent.map { "\(Int($0.rounded()))% used" }
                    ?? Fmt.countLine(used: m.usedCount, limit: m.limitCount)
                    ?? "no value"
                lines.append("    metric \(m.id) (\(m.name)): \(m.state.rawValue) · \(value)")
            }
        }
        lines.append("")
        lines.append("Recent log")
        for l in Diagnostics.shared.recentLines().suffix(120) { lines.append("  " + l) }

        let text = lines.joined(separator: "\n")
        // Always strip secrets and home paths; strip identities unless asked.
        let base = Redact.homePaths(Redact.secrets(text))
        return includeIdentities ? base : Redact.email(base)
    }
}
