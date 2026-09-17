import Foundation

func runPresentationTests() {
    let cal = calendar("America/New_York")
    let now = date(2026, 6, 15, 9, 0, in: cal)

    suite("Formatting") {

        test("countdowns read naturally at every scale") {
            expectEqual(Fmt.compactCountdown(now.addingTimeInterval(90 * 60), now: now), "1h30m")
            expectEqual(Fmt.compactCountdown(now.addingTimeInterval(45 * 60), now: now), "45m")
            expectEqual(Fmt.compactCountdown(now.addingTimeInterval(50 * 3600), now: now), "2d2h")
            expectEqual(Fmt.compactCountdown(now.addingTimeInterval(-60), now: now), "now")
            expectEqual(Fmt.compactCountdown(nil, now: now), "—")
        }

        test("the long remaining line matches the dropdown wording") {
            expectEqual(Fmt.remaining(now.addingTimeInterval(3 * 86400 + 14 * 3600), now: now),
                        "3d 14h remaining")
            expectEqual(Fmt.remaining(now.addingTimeInterval(2 * 3600 + 5 * 60), now: now),
                        "2h 5m remaining")
            expectEqual(Fmt.remaining(now.addingTimeInterval(-1), now: now), "resetting…")
            expectNil(Fmt.remaining(nil, now: now))
        }

        test("percentages always say what they mean") {
            expectEqual(Fmt.usedPercent(88), "88% used")
            expectEqual(Fmt.usedPercent(88.6), "89% used", "rounded, never given false precision")
            expectEqual(Fmt.usedPercent(nil), "—")
        }

        test("count lines show used, limit and remainder") {
            expectEqual(Fmt.countLine(used: 14, limit: 50), "14 / 50 used · 36 remaining")
            expectEqual(Fmt.countLine(used: 14, limit: nil), "14 used")
            expectNil(Fmt.countLine(used: nil, limit: 50))
        }

        test("a provider reset and a local schedule are worded differently") {
            let reset = date(2026, 6, 22, 2, 0, in: cal)
            let fromProvider = Fmt.resetLine(reset, fromProvider: true, now: now, calendar: cal,
                                             locale: Locale(identifier: "en_US_POSIX"))
            let fromLocal = Fmt.resetLine(reset, fromProvider: false, now: now, calendar: cal,
                                          locale: Locale(identifier: "en_US_POSIX"))
            expect(fromProvider.hasPrefix("Resets Monday"), "got \(fromProvider)")
            expect(fromLocal.contains("local schedule"), "got \(fromLocal)")
            expect(fromProvider.contains("remaining"))
        }

        test("an unknown reset says so rather than guessing") {
            expectEqual(Fmt.resetLine(nil, fromProvider: false, now: now, calendar: cal),
                        "Reset time unknown")
        }

        test("a fraction reads as a whole percentage") {
            expectEqual(Fmt.percentage(0.9), "90%")
            expectEqual(Fmt.percentage(1.0), "100%")
            expectEqual(Fmt.percentage(0.605), "61%", "rounded, no false precision")
        }

        test("money formats from minor units") {
            expect(Fmt.money(429, currency: "USD", exponent: 2).contains("4.29"))
        }

        test("the updated line switches to an age once the data is not fresh") {
            expect(Fmt.updatedLine(now.addingTimeInterval(-30), now: now,
                                   locale: Locale(identifier: "en_US_POSIX")).contains("Updated"))
            expectEqual(Fmt.updatedLine(now.addingTimeInterval(-23 * 60), now: now), "Updated 23 min ago")
            expectEqual(Fmt.updatedLine(now.addingTimeInterval(-90 * 60), now: now), "Updated 1h 30m ago")
            expectEqual(Fmt.updatedLine(nil, now: now), "Never updated")
        }
    }

    suite("End-to-end shape of the dropdown data") {
        test("the topology this project was built for renders as four distinct accounts") {
            let store = AccountStore(defaults: scratchDefaults())
            let c1 = store.add(AIAccount(provider: .claude, customDisplayName: "Personal Claude",
                                         credentialSource: .claudeCodeKeychain,
                                         resetOverrides: ResetOverrides(
                                            preferProviderReset: true,
                                            weekly: WeeklyResetRule(weekday: 2, hour: 2, minute: 0))))
            let c2 = store.add(AIAccount(provider: .claude, customDisplayName: "Work Claude",
                                         credentialSource: .appKeychain(id: UUID().uuidString),
                                         resetOverrides: ResetOverrides(
                                            preferProviderReset: true,
                                            weekly: WeeklyResetRule(weekday: 2, hour: 7, minute: 0))))
            let o1 = store.add(AIAccount(provider: .openAI, customDisplayName: "Business Premium",
                                         credentialSource: .codexDefault))
            let o2 = store.add(AIAccount(provider: .openAI, customDisplayName: "Personal Plus",
                                         credentialSource: .file(path: "/Users/example/.codex-personal/auth.json")))

            expectEqual(store.accounts.count, 4)
            expectEqual(store.accounts(for: .claude).count, 2)
            expectEqual(store.accounts(for: .openAI).count, 2)
            expectEqual(store.badge(for: c1), "C1")
            expectEqual(store.badge(for: c2), "C2")
            expectEqual(store.badge(for: o1), "G1")
            expectEqual(store.badge(for: o2), "G2")

            expectEqual(c1.resetOverrides.weekly?.hour, 2)
            expectEqual(c2.resetOverrides.weekly?.hour, 7)
            expect(c1.credentialSource != c2.credentialSource)
            expect(o1.credentialSource != o2.credentialSource)

            // Each account's fallback reset resolves to its own time.
            let sunday = date(2026, 6, 14, 22, 0, in: cal)
            let r1 = ResetSchedule.resolve(providerReset: nil, overrides: c1.resetOverrides,
                                           now: sunday, calendar: cal)
            let r2 = ResetSchedule.resolve(providerReset: nil, overrides: c2.resetOverrides,
                                           now: sunday, calendar: cal)
            expectEqual(components(r1.date!, in: cal).hour, 2)
            expectEqual(components(r2.date!, in: cal).hour, 7)
        }

        test("the whole account list survives a restart with its topology intact") {
            let defaults = scratchDefaults()
            let first = AccountStore(defaults: defaults)
            _ = first.add(AIAccount(provider: .claude, customDisplayName: "Personal Claude",
                                    credentialSource: .claudeCodeKeychain,
                                    resetOverrides: ResetOverrides(preferProviderReset: true,
                                                                   weekly: WeeklyResetRule(weekday: 2, hour: 2, minute: 0))))
            _ = first.add(AIAccount(provider: .claude, customDisplayName: "Work Claude",
                                    credentialSource: .appKeychain(id: "abc"),
                                    resetOverrides: ResetOverrides(preferProviderReset: true,
                                                                   weekly: WeeklyResetRule(weekday: 2, hour: 7, minute: 0))))
            _ = first.add(AIAccount(provider: .openAI, customDisplayName: "Business Premium",
                                    credentialSource: .codexDefault))
            _ = first.add(AIAccount(provider: .openAI, customDisplayName: "Personal Plus",
                                    credentialSource: .file(path: "/Users/example/.codex-personal/auth.json")))

            let reopened = AccountStore(defaults: defaults)
            expectEqual(reopened.accounts.map { $0.displayName },
                        ["Personal Claude", "Work Claude", "Business Premium", "Personal Plus"])
            expectEqual(reopened.accounts[1].resetOverrides.weekly?.hour, 7)
            expectEqual(reopened.accounts[3].credentialSource,
                        .file(path: "/Users/example/.codex-personal/auth.json"))
        }
    }
}
