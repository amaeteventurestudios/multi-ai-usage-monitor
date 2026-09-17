import Foundation

func runDualBarTests() {

    func row(_ role: UsageWindowRole, _ pct: Double?,
             error: Bool = false, stale: Bool = false) -> MenuBarWindowRow {
        MenuBarWindowRow(role: role, percent: pct, hasError: error, isStale: stale)
    }

    func source(_ badge: String, _ provider: String, _ short: String,
                fiveHour: Double?, weekly: Double?,
                fiveHourError: Bool = false, weeklyError: Bool = false,
                accountError: Bool = false, stale: Bool = false) -> MenuBarLayout.Source {
        MenuBarLayout.Source(badge: badge, providerName: provider, shortName: short,
                             fiveHour: row(.fiveHour, fiveHour, error: fiveHourError, stale: stale),
                             weekly: row(.weekly, weekly, error: weeklyError, stale: stale),
                             hasAccountError: accountError)
    }

    /// The topology this phase was designed around.
    let four = [
        source("C", "Claude", "Amaete", fiveHour: 57, weekly: 31),
        source("C", "Claude", "StarLogic", fiveHour: 22, weekly: 18),
        source("O", "OpenAI", "Business", fiveHour: 63, weekly: 90),
        source("O", "OpenAI", "Personal", fiveHour: 0, weekly: 100),
    ]

    suite("Usage window roles") {

        test("a window is classified by the length the provider reports") {
            expectEqual(UsageWindowRole.forWindowSeconds(18_000), .fiveHour)
            expectEqual(UsageWindowRole.forWindowSeconds(604_800), .weekly)
            expectEqual(UsageWindowRole.forWindowSeconds(86_400), .other, "a day is neither")
            expectEqual(UsageWindowRole.forWindowSeconds(-1), .other)
        }

        test("both roles carry the same vocabulary everywhere") {
            expectEqual(UsageWindowRole.fiveHour.displayName, "5-hour")
            expectEqual(UsageWindowRole.fiveHour.shortTag, "5h")
            expectEqual(UsageWindowRole.weekly.displayName, "Weekly")
            expectEqual(UsageWindowRole.weekly.shortTag, "W")
        }

        test("a usage snapshot can be asked for a window by role") {
            let usage = AccountUsage(accountID: UUID(), metrics: [
                UsageMetric(id: "a", name: "5-hour", usedPercent: 57, role: .fiveHour),
                UsageMetric(id: "b", name: "Weekly", usedPercent: 31, role: .weekly),
                UsageMetric(id: "c", name: "Weekly (Opus)", usedPercent: 80, role: .other),
            ])
            expectEqual(usage.metric(for: .fiveHour)?.usedPercent, 57)
            expectEqual(usage.metric(for: .weekly)?.usedPercent, 31)
            expectEqual(usage.metric(for: .weekly)?.remainingPercent, 69, "used and left agree")
        }
    }

    suite("Severity bands, per window") {

        test("each band starts exactly where it should") {
            let cases: [(Double, UsageSeverity)] = [
                (0, .normal), (22, .normal), (57, .normal), (59, .normal),
                (60, .warning), (79, .warning),
                (80, .high), (90, .high), (94, .high),
                (95, .critical), (100, .critical),
            ]
            for (value, expected) in cases {
                expectEqual(UsageSeverity.forUsedPercent(value), expected, "at \\(value)%")
            }
        }

        test("the two windows of one account colour independently") {
            // The case that motivates dual bars: nothing used in the short
            // window, nothing left in the weekly one.
            let personal = four[3]
            expectEqual(personal.fiveHour?.severity, .normal)
            expectEqual(personal.weekly?.severity, .critical)
        }

        test("a window with no value or an error has no severity to show") {
            expectNil(row(.weekly, nil).severity)
            expectNil(row(.weekly, 90, error: true).severity)
        }

        test("severity is spoken as well as coloured") {
            expectEqual(UsageSeverity.normal.accessibilityWord, "normal")
            expectEqual(UsageSeverity.critical.accessibilityWord, "nearly exhausted")
        }
    }

    suite("Window rows") {

        test("a bar fills in proportion to usage used, clamped to the track") {
            expectEqual(row(.weekly, 0).fill, 0)
            expectEqual(row(.weekly, 50).fill, 0.5)
            expectEqual(row(.weekly, 100).fill, 1)
            expectEqual(row(.weekly, 140).fill, 1, "a provider over 100 does not overflow the bar")
            expectEqual(row(.weekly, nil).fill, 0)
        }

        test("a window with no data says so rather than showing a zero") {
            expectEqual(row(.weekly, nil).valueText, "--%")
            expectEqual(row(.weekly, nil, error: true).valueText, "!")
            expectEqual(row(.weekly, 57).valueText, "57%")
            expectEqual(row(.weekly, 56.6).valueText, "57%", "rounded, no false precision")
        }
    }

    suite("Dual bars") {

        test("every account shows both windows") {
            let cells = MenuBarLayout.cells(sources: four, mode: .perAccount,
                                            format: .detailed, usageDisplay: .dualBars)
            expectEqual(cells.count, 4)
            for cell in cells {
                expectEqual(cell.rows.count, 2, "\\(cell.label) shows five-hour and weekly")
                expectEqual(cell.rows[0].role, .fiveHour, "five-hour leads")
                expectEqual(cell.rows[1].role, .weekly)
            }
            expectEqual(cells[0].label, "C Amaete")
            expectEqual(cells[0].rows[0].percent, 57)
            expectEqual(cells[0].rows[1].percent, 31)
        }

        test("labels follow the chosen account format, and order never changes") {
            for (format, expected) in [(PerAccountFormat.detailed,
                                        ["C Amaete", "C StarLogic", "O Business", "O Personal"]),
                                       (.compact, ["C-A", "C-S", "O-B", "O-P"]),
                                       (.minimalLabels, ["A", "S", "B", "P"])] {
                let cells = MenuBarLayout.cells(sources: four, mode: .perAccount,
                                                format: format, usageDisplay: .dualBars)
                expectEqual(cells.map { $0.label }, expected, "\\(format.rawValue)")
            }
        }

        test("the exhausted weekly window is visible beside a calm five-hour one") {
            let cells = MenuBarLayout.cells(sources: four, mode: .perAccount,
                                            format: .minimalLabels, usageDisplay: .dualBars)
            let personal = cells[3]
            expectEqual(personal.label, "P")
            expectEqual(personal.rows[0].severity, .normal, "five-hour is clear")
            expectEqual(personal.rows[1].severity, .critical, "weekly is not")
        }
    }

    suite("Single summary bar") {

        test("the summary is the worse window, never the sum") {
            let cells = MenuBarLayout.cells(sources: four, mode: .perAccount,
                                            format: .detailed, usageDisplay: .singleSummaryBar)
            expectEqual(cells.map { $0.rows.count }, [1, 1, 1, 1])
            expectEqual(cells[0].rows[0].percent, 57, "max(57, 31)")
            expectEqual(cells[1].rows[0].percent, 22, "max(22, 18)")
            expectEqual(cells[2].rows[0].percent, 90, "max(63, 90)")
            expectEqual(cells[3].rows[0].percent, 100, "max(0, 100)")
        }

        test("summing the windows would be meaningless, and is not what happens") {
            expectEqual(four[0].summaryPercent, 57, "not 88")
        }

        test("an account with only one known window summarises from that one") {
            let partial = MenuBarLayout.Source(badge: "C", providerName: "Claude",
                                               shortName: "Amaete",
                                               fiveHour: row(.fiveHour, 42),
                                               weekly: nil, hasAccountError: false)
            expectEqual(partial.summaryPercent, 42)
        }
    }

    suite("Text only") {

        test("both windows are named and valued, with no bars") {
            let title = MenuBarLayout.textTitle(sources: four, mode: .perAccount,
                                                format: .detailed, usageDisplay: .textOnly)
            expectEqual(title, "C Amaete 5h57% W31% · C StarLogic 5h22% W18% · "
                             + "O Business 5h63% W90% · O Personal 5h0% W100%")
        }

        test("minimal labels keep it as short as it can honestly be") {
            expectEqual(MenuBarLayout.textTitle(sources: four, mode: .perAccount,
                                                format: .minimalLabels, usageDisplay: .textOnly),
                        "A 5h57% W31% · S 5h22% W18% · B 5h63% W90% · P 5h0% W100%")
        }

        test("percentages can be switched off without losing the windows") {
            expectEqual(MenuBarLayout.textTitle(sources: four, mode: .perAccount,
                                                format: .compact, usageDisplay: .textOnly,
                                                showPercentages: false),
                        "C-A 5h W · C-S 5h W · O-B 5h W · O-P 5h W")
        }

        test("bar modes still produce sensible text for the modes that need it") {
            expectEqual(MenuBarLayout.textTitle(sources: four, mode: .perAccount,
                                                format: .compact, usageDisplay: .singleSummaryBar),
                        "C-A 57% · C-S 22% · O-B 90% · O-P 100%")
        }
    }

    suite("Failure and staleness in the menu bar") {

        test("one failed window does not mark the whole account failed") {
            let mixed = [source("O", "OpenAI", "Business", fiveHour: 63, weekly: nil,
                                weeklyError: true)]
            let cells = MenuBarLayout.cells(sources: mixed, mode: .perAccount,
                                            format: .detailed, usageDisplay: .dualBars)
            expectEqual(cells[0].rows[0].percent, 63, "the good window still reports")
            expectEqual(cells[0].rows[0].valueText, "63%")
            expect(cells[0].rows[1].hasError)
            expectEqual(cells[0].rows[1].valueText, "!")
        }

        test("a failing account stays visible rather than disappearing") {
            let mixed = [four[0],
                         source("C", "Claude", "StarLogic", fiveHour: nil, weekly: nil,
                                fiveHourError: true, weeklyError: true, accountError: true),
                         four[2]]
            let title = MenuBarLayout.textTitle(sources: mixed, mode: .perAccount,
                                                format: .detailed, usageDisplay: .textOnly)
            expectEqual(title, "C Amaete 5h57% W31% · C StarLogic 5h! W! · O Business 5h63% W90%",
                        "no second flag: both windows already say so themselves")
        }

        test("stale values are kept, not discarded") {
            let stale = [source("C", "Claude", "Amaete", fiveHour: 57, weekly: 31, stale: true)]
            let cells = MenuBarLayout.cells(sources: stale, mode: .perAccount,
                                            format: .detailed, usageDisplay: .dualBars)
            expectEqual(cells[0].rows[0].percent, 57, "the number survives")
            expect(cells[0].rows[0].isStale, "and is marked as no longer current")
            expectEqual(cells[0].rows[0].severity, .normal, "it still colours honestly")
        }

        test("an account with an error but no metrics still shows two flagged rows") {
            let store = AccountStore(defaults: scratchDefaults())
            let account = store.add(AIAccount(provider: .openAI, customShortName: "Business",
                                              credentialSource: .appKeychain(id: "k")))
            let states: [UUID: AccountRuntimeState] = [account.id: AccountRuntimeState(
                usage: nil,
                error: AccountError(kind: .expiredCredential, message: "Authentication expired."),
                isRefreshing: false, lastSuccess: nil)]
            let sources = MenuBarLayout.sources(accounts: store.accounts, states: states)
            expectEqual(sources.count, 1)
            expect(sources[0].fiveHour?.hasError == true)
            expect(sources[0].weekly?.hasError == true)
            expect(sources[0].anyError)
        }
    }

    suite("Provider mode with two windows") {

        test("each window takes the worst account, independently") {
            let grouped = MenuBarLayout.byProvider(four)
            expectEqual(grouped.count, 2)
            expectEqual(grouped[0].providerName, "Claude")
            expectEqual(grouped[0].fiveHour?.percent, 57, "max(57, 22)")
            expectEqual(grouped[0].weekly?.percent, 31, "max(31, 18)")
            expectEqual(grouped[1].providerName, "OpenAI")
            expectEqual(grouped[1].fiveHour?.percent, 63, "max(63, 0)")
            expectEqual(grouped[1].weekly?.percent, 100, "max(90, 100)")
        }

        test("a provider's two figures may come from different accounts") {
            // OpenAI's five-hour worst is Business; its weekly worst is Personal.
            let grouped = MenuBarLayout.byProvider(four)
            expectEqual(grouped[1].fiveHour?.percent, 63)
            expectEqual(grouped[1].weekly?.percent, 100)
        }

        test("provider mode labels by provider, not by account") {
            let cells = MenuBarLayout.cells(sources: four, mode: .provider,
                                            format: .minimalLabels, usageDisplay: .dualBars)
            expectEqual(cells.map { $0.label }, ["Claude", "OpenAI"])
            expectEqual(cells[0].rows.count, 2)
        }

        test("a provider with any failing account is flagged") {
            let mixed = [four[0],
                         source("C", "Claude", "StarLogic", fiveHour: nil, weekly: nil,
                                fiveHourError: true, weeklyError: true),
                         four[2]]
            let grouped = MenuBarLayout.byProvider(mixed)
            expect(grouped[0].fiveHour?.hasError == true)
            expect(grouped[1].fiveHour?.hasError == false, "OpenAI is unaffected")
        }
    }

    suite("Icon only stays minimal") {

        test("no bars and no labels, whatever else is configured") {
            for usage in UsageDisplayMode.allCases {
                expectEqual(MenuBarLayout.cells(sources: four, mode: .iconOnly,
                                                format: .detailed, usageDisplay: usage).count, 0)
                expectEqual(MenuBarLayout.textTitle(sources: four, mode: .iconOnly,
                                                    format: .detailed, usageDisplay: usage), "AI")
            }
        }

        test("but it still admits that something needs attention") {
            let failing = [source("C", "Claude", "Amaete", fiveHour: nil, weekly: nil,
                                  accountError: true)]
            expectEqual(MenuBarLayout.textTitle(sources: failing, mode: .iconOnly,
                                                format: .detailed, usageDisplay: .dualBars), "AI !")
        }
    }

    suite("Mini bar lengths") {

        test("the three lengths are distinct and ordered") {
            expect(MiniBarLength.short.width < MiniBarLength.medium.width)
            expect(MiniBarLength.medium.width < MiniBarLength.long.width)
            expectEqual(MiniBarLength.short.cellCount, 4)
            expectEqual(MiniBarLength.medium.cellCount, 8)
            expectEqual(MiniBarLength.long.cellCount, 12)
        }

        test("length does not change what is reported, only how wide it is drawn") {
            // Both windows are present at every length: the shortest option
            // trades width, never information.
            for length in MiniBarLength.allCases {
                let cells = MenuBarLayout.cells(sources: four, mode: .perAccount,
                                                format: .compact, usageDisplay: .dualBars)
                expectEqual(cells.count, 4, "\\(length.rawValue)")
                expectEqual(cells[0].rows.count, 2)
            }
        }
    }

    suite("Accessibility") {

        test("every value is spoken, so colour is never the only signal") {
            let text = MenuBarLayout.accessibilityText(four[3], label: "O Personal",
                                                       usageDisplay: .dualBars)
            expect(text.contains("Personal"))
            expect(text.contains("five-hour usage, 0 percent used, normal"))
            expect(text.contains("weekly usage, 100 percent used, nearly exhausted"))
        }

        test("an unavailable window is spoken as unavailable") {
            let mixed = source("O", "OpenAI", "Business", fiveHour: 63, weekly: nil,
                               weeklyError: true)
            let text = MenuBarLayout.accessibilityText(mixed, label: "O Business",
                                                       usageDisplay: .dualBars)
            expect(text.contains("weekly usage unavailable"), "got \\(text)")
        }

        test("the summary mode speaks the summary") {
            let text = MenuBarLayout.accessibilityText(four[2], label: "O Business",
                                                       usageDisplay: .singleSummaryBar)
            expect(text.contains("highest usage 90 percent used"))
        }

        test("an account needing attention says so") {
            let failing = source("C", "Claude", "Amaete", fiveHour: 10, weekly: 10,
                                 accountError: true)
            expect(MenuBarLayout.accessibilityText(failing, label: "C Amaete",
                                                   usageDisplay: .dualBars)
                .contains("needs attention"))
        }
    }

    suite("Display settings for the new options") {

        test("defaults are dual bars at medium length") {
            let s = AppSettings(defaults: scratchDefaults())
            expectEqual(s.usageDisplay, .dualBars)
            expectEqual(s.miniBarLength, .medium)
        }

        test("both persist across a restart") {
            let defaults = scratchDefaults()
            let first = AppSettings(defaults: defaults)
            first.usageDisplay = .textOnly
            first.miniBarLength = .long
            let reopened = AppSettings(defaults: defaults)
            expectEqual(reopened.usageDisplay, .textOnly)
            expectEqual(reopened.miniBarLength, .long)
        }

        test("resetting restores them without disturbing the opacity work") {
            let s = AppSettings(defaults: scratchDefaults())
            s.usageDisplay = .textOnly
            s.miniBarLength = .short
            s.resetToDefaults()
            expectEqual(s.usageDisplay, .dualBars)
            expectEqual(s.miniBarLength, .medium)
            expectEqual(s.backgroundOpacity, 0.95)
            expectEqual(s.warningThresholdPercent, 90, "and the alert threshold stays at 90%")
        }

        test("every option explains itself") {
            for m in UsageDisplayMode.allCases { expect(m.explanation.count > 20, m.rawValue) }
            for l in MiniBarLength.allCases { expect(!l.displayName.isEmpty, l.rawValue) }
        }
    }

    suite("A window the provider does not report stays absent") {

        test("a null secondary window produces no five-hour metric at all") {
            var obj = fixture("openai-usage.sample.json")
            var rl = obj["rate_limit"] as! [String: Any]
            rl["secondary_window"] = NSNull()
            obj["rate_limit"] = rl
            let usage = try OpenAIUsageParser.parse(obj, account: makeAccount(.openAI))
            expectNil(usage.metric(for: .fiveHour),
                      "an unreported window is absent, never a confident 0%")
            expectNotNil(usage.metric(for: .weekly), "and the reported one is unaffected")
        }

        test("the menu bar draws one row for that account, not an empty second one") {
            var obj = fixture("openai-usage.sample.json")
            var rl = obj["rate_limit"] as! [String: Any]
            rl["secondary_window"] = NSNull()
            obj["rate_limit"] = rl

            let store = AccountStore(defaults: scratchDefaults())
            let account = store.add(AIAccount(provider: .openAI, customShortName: "Business",
                                              credentialSource: .appKeychain(id: "k")))
            let usage = try OpenAIUsageParser.parse(obj, account: account)
            let states: [UUID: AccountRuntimeState] = [account.id: AccountRuntimeState(
                usage: usage, error: nil, isRefreshing: false, lastSuccess: Date())]

            let sources = MenuBarLayout.sources(accounts: store.accounts, states: states)
            expectNil(sources[0].fiveHour, "no five-hour row is invented")
            expectEqual(sources[0].weekly?.percent, 89)

            let cells = MenuBarLayout.cells(sources: sources, mode: .perAccount,
                                            format: .detailed, usageDisplay: .dualBars)
            expectEqual(cells[0].rows.count, 1, "one window reported, one row drawn")
            expectEqual(cells[0].rows[0].role, .weekly)
            expectEqual(MenuBarLayout.textTitle(sources: sources, mode: .perAccount,
                                                format: .detailed, usageDisplay: .textOnly),
                        "O Business W89%")
        }
    }

    suite("Menu bar sources come from real account state") {

        test("both windows are read from the account's own metrics") {
            let store = AccountStore(defaults: scratchDefaults())
            let account = store.add(AIAccount(provider: .claude, customShortName: "Amaete",
                                              credentialSource: .appKeychain(id: "k")))
            let states: [UUID: AccountRuntimeState] = [account.id: AccountRuntimeState(
                usage: AccountUsage(accountID: account.id, metrics: [
                    UsageMetric(id: "a", name: "5-hour", usedPercent: 57, role: .fiveHour),
                    UsageMetric(id: "b", name: "Weekly", usedPercent: 31, role: .weekly),
                ], fetchedAt: Date()),
                error: nil, isRefreshing: false, lastSuccess: Date())]

            let sources = MenuBarLayout.sources(accounts: store.accounts, states: states)
            expectEqual(sources[0].shortName, "Amaete")
            expectEqual(sources[0].badge, "C")
            expectEqual(sources[0].fiveHour?.percent, 57)
            expectEqual(sources[0].weekly?.percent, 31)
        }

        test("an account with no data yet previews as unknown, not as zero") {
            let store = AccountStore(defaults: scratchDefaults())
            _ = store.add(AIAccount(provider: .claude, customShortName: "Amaete",
                                    credentialSource: .appKeychain(id: "k")))
            let sources = MenuBarLayout.sources(accounts: store.accounts, states: [:])
            expectEqual(sources.count, 1)
            expectNil(sources[0].fiveHour, "no metric and no error means no row to draw")
            expectNil(sources[0].summaryPercent)
        }

        test("old data is marked stale by the same rule the dropdown uses") {
            let store = AccountStore(defaults: scratchDefaults())
            let account = store.add(AIAccount(provider: .claude, customShortName: "Amaete",
                                              credentialSource: .appKeychain(id: "k")))
            let old = Date().addingTimeInterval(-3600)
            let states: [UUID: AccountRuntimeState] = [account.id: AccountRuntimeState(
                usage: AccountUsage(accountID: account.id, metrics: [
                    UsageMetric(id: "a", name: "5-hour", usedPercent: 57, role: .fiveHour),
                ], fetchedAt: old),
                error: nil, isRefreshing: false, lastSuccess: old)]
            let sources = MenuBarLayout.sources(accounts: store.accounts, states: states)
            expect(sources[0].fiveHour?.isStale == true)
            expectEqual(sources[0].fiveHour?.percent, 57, "and keeps its value")
        }

        test("a disabled account contributes nothing") {
            let store = AccountStore(defaults: scratchDefaults())
            let account = store.add(makeAccount(.claude, name: "Off"))
            store.setEnabled(false, id: account.id)
            expectEqual(MenuBarLayout.sources(accounts: store.accounts, states: [:]).count, 0)
        }
    }
}
