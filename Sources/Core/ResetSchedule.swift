import Foundation

/// Weekly reset arithmetic.
///
/// Deliberately calendar-based rather than `now + 7 * 24 * 3600`: across a
/// daylight-saving transition a week is 167 or 169 hours, and a reset advertised
/// as "Monday 2:00 AM" must stay at 2:00 AM local time on both sides of the
/// change. `Calendar.nextDate(after:matching:)` does exactly that.
enum ResetSchedule {

    /// The next occurrence of `rule` strictly after `date`.
    ///
    /// A reset landing exactly on `date` counts as already happened, so the
    /// answer is always in the future — the countdown never sticks at "now".
    static func nextReset(after date: Date,
                          rule: WeeklyResetRule,
                          calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.weekday = rule.weekday
        components.hour = rule.hour
        components.minute = rule.minute
        components.second = 0
        return calendar.nextDate(after: date,
                                 matching: components,
                                 matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first,
                                 direction: .forward)
    }

    /// The most recent occurrence of `rule` at or before `date`. Used to decide
    /// which usage window a notification belongs to when the provider gives us
    /// no reset timestamp of its own.
    static func previousReset(onOrBefore date: Date,
                              rule: WeeklyResetRule,
                              calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.weekday = rule.weekday
        components.hour = rule.hour
        components.minute = rule.minute
        components.second = 0
        return calendar.nextDate(after: date.addingTimeInterval(1),
                                 matching: components,
                                 matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first,
                                 direction: .backward)
    }

    /// Resolve the reset shown for a metric.
    ///
    /// A provider-supplied timestamp is authoritative and is reported as such,
    /// so the UI never presents a locally configured guess as if the provider
    /// had said it. The local rule is a fallback, not an override — unless the
    /// account explicitly turns `preferProviderReset` off.
    static func resolve(providerReset: Date?,
                        overrides: ResetOverrides,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> (date: Date?, fromProvider: Bool) {
        let local = overrides.weekly.flatMap { nextReset(after: now, rule: $0, calendar: calendar) }
        if overrides.preferProviderReset {
            if let p = providerReset { return (p, true) }
            return (local, false)
        }
        if let l = local { return (l, false) }
        return (providerReset, providerReset != nil)
    }
}
