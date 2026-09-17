// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Umanah. See NOTICE.

import Foundation

/// All user-visible number and date formatting, kept together so the app says
/// the same thing the same way everywhere — and so it can be tested without a
/// UI.
enum Fmt {

    /// Compact countdown for the menu bar: "4h12m", "37m", "2d3h".
    static func compactCountdown(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "—" }
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "now" }
        let hours = Int(delta) / 3600
        let mins = (Int(delta) % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d\(hours % 24)h" }
        if hours > 0 { return "\(hours)h\(mins)m" }
        return "\(mins)m"
    }

    /// Long countdown for the dropdown: "3d 14h remaining".
    static func remaining(_ date: Date?, now: Date = Date()) -> String? {
        guard let date = date else { return nil }
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "resetting…" }
        let hours = Int(delta) / 3600
        let mins = (Int(delta) % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h remaining" }
        if hours > 0 { return "\(hours)h \(mins)m remaining" }
        return "\(mins)m remaining"
    }

    /// Absolute reset time. No invented precision: we print to the minute
    /// because that is the resolution providers actually give us.
    static func absoluteReset(_ date: Date?,
                              now: Date = Date(),
                              calendar: Calendar = .current,
                              locale: Locale = .current) -> String? {
        guard let date = date else { return nil }
        let df = DateFormatter()
        df.locale = locale
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "EEEE h:mm a"
        return df.string(from: date)
    }

    /// The reset line under a usage bar. `fromProvider` changes the wording so a
    /// locally configured schedule is never mistaken for the provider's word.
    static func resetLine(_ date: Date?,
                          fromProvider: Bool,
                          now: Date = Date(),
                          calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        guard let date = date, let abs = absoluteReset(date, now: now, calendar: calendar, locale: locale) else {
            return "Reset time unknown"
        }
        let prefix = fromProvider ? "Resets" : "Resets (local schedule)"
        if let rem = remaining(date, now: now) {
            return "\(prefix) \(abs) · \(rem)"
        }
        return "\(prefix) \(abs)"
    }

    /// Percentages are always *used*. The word is part of the string so the
    /// number can never be read as "remaining".
    static func usedPercent(_ value: Double?) -> String {
        guard let v = value else { return "—" }
        return "\(Int(v.rounded()))% used"
    }

    /// Count-based allowance: "14 / 50 used · 36 remaining".
    static func countLine(used: Int?, limit: Int?) -> String? {
        guard let used = used else { return nil }
        guard let limit = limit else { return "\(used) used" }
        return "\(used) / \(limit) used · \(max(0, limit - used)) remaining"
    }

    /// Name a rate-limit window from its length, since providers give seconds
    /// rather than a label: 18000 → "5-hour", 604800 → "Weekly".
    static func windowLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "Usage" }
        if seconds < 3600 { return "\(max(1, seconds / 60))-minute" }
        if seconds == 86_400 { return "Daily" }
        if seconds == 604_800 { return "Weekly" }
        if seconds >= 2_592_000 && seconds <= 2_678_400 { return "Monthly" }
        if seconds < 86_400 { return "\(seconds / 3600)-hour" }
        return "\(seconds / 86_400)-day"
    }

    /// Money from minor units, e.g. (429, "USD", 2) → "$4.29".
    static func money(_ minor: Int, currency: String, exponent: Int) -> String {
        let value = Double(minor) / pow(10.0, Double(exponent))
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = exponent
        f.minimumFractionDigits = exponent
        return f.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
    }

    /// "Updated 11:04:22 AM" / "Updated 23 min ago" for stale data.
    static func updatedLine(_ date: Date?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let date = date else { return "Never updated" }
        let age = now.timeIntervalSince(date)
        if age >= 120 {
            let mins = Int(age / 60)
            if mins >= 60 { return "Updated \(mins / 60)h \(mins % 60)m ago" }
            return "Updated \(mins) min ago"
        }
        let df = DateFormatter()
        df.locale = locale
        df.dateFormat = "h:mm:ss a"
        return "Updated \(df.string(from: date))"
    }
}
