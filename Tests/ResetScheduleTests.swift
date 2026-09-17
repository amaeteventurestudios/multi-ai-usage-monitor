import Foundation

/// Weekly reset arithmetic, including the two schedules the project was built
/// around (Monday 02:00 and Monday 07:00) and both daylight-saving transitions.
func runResetScheduleTests() {
    suite("Reset schedule") {
        let cal = calendar("America/New_York")
        let mondayAt2 = WeeklyResetRule(weekday: 2, hour: 2, minute: 0)
        let mondayAt7 = WeeklyResetRule(weekday: 2, hour: 7, minute: 0)

        test("Sunday before the reset resolves to the next morning") {
            let now = date(2026, 6, 14, 22, 0, in: cal)     // Sunday 22:00
            let next = ResetSchedule.nextReset(after: now, rule: mondayAt2, calendar: cal)
            let c = components(next!, in: cal)
            expectEqual(c.day, 15)
            expectEqual(c.hour, 2)
            expectEqual(c.minute, 0)
        }

        test("Monday 01:59 resolves to 02:00 the same morning") {
            let now = date(2026, 6, 15, 1, 59, in: cal)
            let next = ResetSchedule.nextReset(after: now, rule: mondayAt2, calendar: cal)!
            expectEqual(next.timeIntervalSince(now), 60, "one minute away")
        }

        test("Monday exactly 02:00 resolves to the following week") {
            let now = date(2026, 6, 15, 2, 0, in: cal)
            let next = ResetSchedule.nextReset(after: now, rule: mondayAt2, calendar: cal)!
            let c = components(next, in: cal)
            expectEqual(c.day, 22, "a reset landing on now has already happened")
            expectEqual(c.hour, 2)
        }

        test("Monday 02:01 resolves to the following week") {
            let now = date(2026, 6, 15, 2, 1, in: cal)
            let c = components(ResetSchedule.nextReset(after: now, rule: mondayAt2, calendar: cal)!, in: cal)
            expectEqual(c.day, 22)
        }

        test("Monday 06:59 still reaches the 07:00 reset today") {
            let now = date(2026, 6, 15, 6, 59, in: cal)
            let next = ResetSchedule.nextReset(after: now, rule: mondayAt7, calendar: cal)!
            let c = components(next, in: cal)
            expectEqual(c.day, 15)
            expectEqual(c.hour, 7)
        }

        test("Monday exactly 07:00 resolves to the following week") {
            let now = date(2026, 6, 15, 7, 0, in: cal)
            let c = components(ResetSchedule.nextReset(after: now, rule: mondayAt7, calendar: cal)!, in: cal)
            expectEqual(c.day, 22)
            expectEqual(c.hour, 7)
        }

        test("the two accounts' schedules stay five hours apart, not merged") {
            let now = date(2026, 6, 14, 22, 0, in: cal)
            let a = ResetSchedule.nextReset(after: now, rule: mondayAt2, calendar: cal)!
            let b = ResetSchedule.nextReset(after: now, rule: mondayAt7, calendar: cal)!
            expectEqual(b.timeIntervalSince(a), 5 * 3600)
        }

        test("spring-forward week is 167 hours, and the reset stays at 02:00 local") {
            // US DST begins Sunday 8 March 2026, between these two Mondays.
            let before = date(2026, 3, 1, 0, 0, in: cal)
            let first = ResetSchedule.nextReset(after: before, rule: mondayAt2, calendar: cal)!
            let second = ResetSchedule.nextReset(after: first, rule: mondayAt2, calendar: cal)!
            expectEqual(second.timeIntervalSince(first), 167 * 3600, "a short week, not 168h")
            expectEqual(components(first, in: cal).hour, 2)
            expectEqual(components(second, in: cal).hour, 2, "still 2 AM after the clocks move")
        }

        test("fall-back week is 169 hours, and the reset stays at 02:00 local") {
            // US DST ends Sunday 1 November 2026.
            let before = date(2026, 10, 25, 0, 0, in: cal)
            let first = ResetSchedule.nextReset(after: before, rule: mondayAt2, calendar: cal)!
            let second = ResetSchedule.nextReset(after: first, rule: mondayAt2, calendar: cal)!
            expectEqual(second.timeIntervalSince(first), 169 * 3600, "a long week, not 168h")
            expectEqual(components(second, in: cal).hour, 2)
        }

        test("a naive seven-day addition would be wrong across a DST change") {
            let before = date(2026, 3, 1, 0, 0, in: cal)
            let first = ResetSchedule.nextReset(after: before, rule: mondayAt2, calendar: cal)!
            let naive = first.addingTimeInterval(7 * 24 * 3600)
            let correct = ResetSchedule.nextReset(after: first, rule: mondayAt2, calendar: cal)!
            expect(naive != correct, "the calendar answer must differ from now + 7 days")
            expectEqual(components(naive, in: cal).hour, 3, "the naive answer drifts to 3 AM")
        }

        test("the same rule resolves differently in a different timezone") {
            let london = calendar("Europe/London")
            let now = date(2026, 6, 14, 22, 0, in: london)
            let next = ResetSchedule.nextReset(after: now, rule: mondayAt2, calendar: london)!
            expectEqual(components(next, in: london).hour, 2, "2 AM in the configured zone")
        }

        test("previousReset finds the window a metric currently sits in") {
            let now = date(2026, 6, 17, 12, 0, in: cal)   // Wednesday
            let prev = ResetSchedule.previousReset(onOrBefore: now, rule: mondayAt2, calendar: cal)!
            let c = components(prev, in: cal)
            expectEqual(c.day, 15)
            expectEqual(c.hour, 2)
        }

        test("a provider reset wins over a local rule and is marked authoritative") {
            let now = date(2026, 6, 14, 22, 0, in: cal)
            let providerReset = date(2026, 6, 16, 9, 30, in: cal)
            let resolved = ResetSchedule.resolve(
                providerReset: providerReset,
                overrides: ResetOverrides(preferProviderReset: true, weekly: mondayAt2),
                now: now, calendar: cal)
            expectEqual(resolved.date, providerReset)
            expect(resolved.fromProvider, "must be reported as the provider's own value")
        }

        test("the local rule is used when the provider says nothing, and is marked local") {
            let now = date(2026, 6, 14, 22, 0, in: cal)
            let resolved = ResetSchedule.resolve(
                providerReset: nil,
                overrides: ResetOverrides(preferProviderReset: true, weekly: mondayAt2),
                now: now, calendar: cal)
            expectEqual(components(resolved.date!, in: cal).hour, 2)
            expect(!resolved.fromProvider, "a local guess must never claim to be the provider's")
        }

        test("with no provider value and no rule, the reset is simply unknown") {
            let resolved = ResetSchedule.resolve(providerReset: nil, overrides: ResetOverrides(),
                                                 now: Date(), calendar: cal)
            expectNil(resolved.date)
        }

        test("turning off preferProviderReset lets the local rule take over") {
            let now = date(2026, 6, 14, 22, 0, in: cal)
            let providerReset = date(2026, 6, 16, 9, 30, in: cal)
            let resolved = ResetSchedule.resolve(
                providerReset: providerReset,
                overrides: ResetOverrides(preferProviderReset: false, weekly: mondayAt7),
                now: now, calendar: cal)
            expectEqual(components(resolved.date!, in: cal).hour, 7)
            expect(!resolved.fromProvider)
        }

        test("out-of-range rule values are clamped rather than crashing") {
            let rule = WeeklyResetRule(weekday: 99, hour: 48, minute: -3)
            expectEqual(rule.weekday, 7)
            expectEqual(rule.hour, 23)
            expectEqual(rule.minute, 0)
        }
    }
}
