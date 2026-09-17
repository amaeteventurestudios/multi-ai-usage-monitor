import Foundation

func runMenuFormatTests() {

    /// One account with a single known window, which is all these label and
    /// ordering tests need. Dual-window behaviour is covered in DualBarTests.
    func entry(_ badge: String, _ provider: String, _ short: String,
               _ pct: Double?, error: Bool = false) -> MenuBarLayout.Source {
        MenuBarLayout.Source(
            badge: badge, providerName: provider, shortName: short,
            fiveHour: MenuBarWindowRow(role: .fiveHour, percent: pct,
                                       hasError: error, isStale: false),
            weekly: nil, hasAccountError: error)
    }

    /// The single-summary text path renders "label percent", which is what the
    /// label and ordering rules are about.
    func title(_ sources: [MenuBarLayout.Source],
               mode: MenuBarSummaryMode = .perAccount,
               format: PerAccountFormat = .detailed,
               showPercentages: Bool = true,
               onlyHighest: Bool = false) -> String? {
        MenuBarLayout.textTitle(sources: sources, mode: mode, format: format,
                                usageDisplay: .singleSummaryBar,
                                showPercentages: showPercentages, onlyHighest: onlyHighest)
    }

    /// The topology this phase was built around.
    let four = [
        entry("C", "Claude", "Amaete", 57),
        entry("C", "Claude", "StarLogic", 22),
        entry("O", "OpenAI", "Business", 90),
        entry("O", "OpenAI", "Personal", 41),
    ]

    suite("Short names") {

        test("a Claude account is aliased from its e-mail, not its plan") {
            let identity = makeIdentity(email: "amaete@gmail.com", plan: "Pro")
            expectEqual(ShortName.derive(provider: .claude, identity: identity), "Amaete")
        }

        test("an OpenAI account prefers its plan, which is what tells two apart") {
            expectEqual(ShortName.derive(provider: .openAI,
                                         identity: makeIdentity(email: "work@example.com",
                                                                plan: "Business")), "Business")
            expectEqual(ShortName.derive(provider: .openAI,
                                         identity: makeIdentity(email: "home@example.com",
                                                                plan: "Plus")), "Plus")
        }

        test("an OpenAI account with no known plan falls back to the e-mail") {
            expectEqual(ShortName.derive(provider: .openAI,
                                         identity: makeIdentity(email: "home@example.com")), "Home")
        }

        test("an unidentified account is aliased by its provider") {
            expectEqual(ShortName.derive(provider: .claude, identity: nil), "Claude")
            expectEqual(ShortName.derive(provider: .openAI, identity: nil), "OpenAI")
        }

        test("only the first segment of an address is used, and it is capitalised") {
            expectEqual(ShortName.fromEmail("john.doe@example.com"), "John")
            expectEqual(ShortName.fromEmail("jane_smith@example.com"), "Jane")
            expectEqual(ShortName.fromEmail("a-b+c@example.com"), "A")
            expectEqual(ShortName.fromEmail("starlogic@gmail.com"), "Starlogic")
            expectNil(ShortName.fromEmail(nil))
            expectNil(ShortName.fromEmail("@example.com"), "a missing local part is not a name")
            expectNil(ShortName.fromEmail(""))
        }

        test("a very long address is trimmed to something a menu bar can hold") {
            let long = ShortName.fromEmail("abcdefghijklmnopqrstuvwxyz@example.com")!
            expectEqual(long.count, ShortName.maximumLength)
        }

        test("an alias the user typed wins, and clearing it returns to the derived one") {
            let store = AccountStore(defaults: scratchDefaults())
            let account = store.add(AIAccount(provider: .claude,
                                              identity: makeIdentity(email: "amaete@gmail.com"),
                                              credentialSource: .appKeychain(id: "k")))
            expectEqual(store.account(id: account.id)?.shortDisplayName, "Amaete")
            store.setShortName("Personal Mac", id: account.id)
            expectEqual(store.account(id: account.id)?.shortDisplayName, "Personal Mac")
            store.setShortName("  ", id: account.id)
            expectEqual(store.account(id: account.id)?.shortDisplayName, "Amaete")
        }

        test("an alias survives a restart, and identity detection does not clobber it") {
            let defaults = scratchDefaults()
            let first = AccountStore(defaults: defaults)
            let account = first.add(AIAccount(provider: .claude,
                                              customShortName: "StarLogic",
                                              credentialSource: .appKeychain(id: "k")))
            first.setIdentity(makeIdentity(email: "starlogic@gmail.com", plan: "Pro"),
                              id: account.id)
            expectEqual(first.account(id: account.id)?.shortDisplayName, "StarLogic",
                        "discovering identity must not overwrite a chosen alias")

            let reopened = AccountStore(defaults: defaults)
            expectEqual(reopened.accounts[0].shortDisplayName, "StarLogic")
            expectEqual(reopened.accounts[0].displayName, "Claude (starlogic@gmail.com)",
                        "the full identity is still the canonical name")
        }

        test("an account stored before aliases existed derives one") {
            let json = """
            [{"id":"00000000-0000-4000-8000-000000000003","provider":"claude",
              "enabled":true,"order":0,
              "identity":{"email":"amaete@gmail.com","verified":true,
                          "detectedAt":770000000},
              "credentialSource":{"kind":"claudeCodeKeychain"},
              "resetOverrides":{"preferProviderReset":true}}]
            """
            let defaults = scratchDefaults()
            defaults.set(Data(json.utf8), forKey: "accounts.v1")
            let store = AccountStore(defaults: defaults)
            expectEqual(store.accounts.count, 1)
            expectNil(store.accounts[0].customShortName, "nothing is written until the user types one")
            expectEqual(store.accounts[0].shortDisplayName, "Amaete")
        }
    }

    suite("Abbreviation") {

        test("distinct names get a single letter") {
            let out = ShortName.uniqueAbbreviations(["Amaete", "Business", "Personal"],
                                                    groups: ["", "", ""])
            expectEqual(out, ["A", "B", "P"])
        }

        test("colliding names expand only as far as they must") {
            // The example from the brief: Business and Beta both want "B".
            let out = ShortName.uniqueAbbreviations(["Business", "Beta"], groups: ["O", "O"])
            expectEqual(out, ["Bu", "Be"])
        }

        test("Personal and Pro expand to two letters, not more") {
            expectEqual(ShortName.uniqueAbbreviations(["Personal", "Pro"], groups: ["", ""]),
                        ["Pe", "Pr"])
        }

        test("a long shared prefix expands only to the first difference") {
            // They differ at the seventh character, so seven is enough.
            expectEqual(ShortName.uniqueAbbreviations(["Production", "Produce"], groups: ["", ""]),
                        ["Product", "Produce"])
        }

        test("names in different groups may share an abbreviation") {
            // "C-B" and "G-B" are not ambiguous: the provider prefix separates them.
            expectEqual(ShortName.uniqueAbbreviations(["Business", "Business"], groups: ["C", "O"]),
                        ["B", "B"])
        }

        test("genuinely identical names in one group are numbered rather than left ambiguous") {
            let out = ShortName.uniqueAbbreviations(["Business", "Business"], groups: ["O", "O"])
            expectEqual(out.count, 2)
            expect(out[0] != out[1], "an ambiguous menu bar is worse than an ugly one, got \\(out)")
        }

        test("abbreviation is deterministic and order-stable") {
            let names = ["Amaete", "StarLogic", "Business", "Personal"]
            let groups = ["C", "C", "G", "G"]
            expectEqual(ShortName.uniqueAbbreviations(names, groups: groups),
                        ShortName.uniqueAbbreviations(names, groups: groups))
        }

        test("an empty name does not crash the menu bar") {
            expectEqual(ShortName.uniqueAbbreviations([""], groups: [""]), ["?"])
        }
    }

    suite("Menu bar formats") {

        test("detailed names the provider and the account in full") {
            expectEqual(title(four, format: .detailed),
                        "C Amaete 57% · C StarLogic 22% · O Business 90% · O Personal 41%")
        }

        test("compact abbreviates behind the provider initial") {
            expectEqual(title(four, format: .compact),
                        "C-A 57% · C-S 22% · O-B 90% · O-P 41%")
        }

        test("minimal labels drop the provider entirely") {
            expectEqual(title(four, format: .minimalLabels),
                        "A 57% · S 22% · B 90% · P 41%")
        }

        test("every format honours account order rather than sorting by usage") {
            // Business is the highest, but it stays third because that is where
            // the user put it.
            for format in PerAccountFormat.allCases {
                let rendered = title(four, format: format)!
                let parts = rendered.components(separatedBy: " · ")
                expectEqual(parts.count, 4)
                expect(parts[0].hasSuffix("57%"), "\\(format.rawValue): first is Amaete")
                expect(parts[3].hasSuffix("41%"), "\\(format.rawValue): last is Personal")
            }
        }

        test("a failing account stays visible in every format") {
            let failing = [four[0],
                           entry("C", "Claude", "StarLogic", nil, error: true),
                           four[2], four[3]]
            expectEqual(title(failing, format: .detailed),
                        "C Amaete 57% · C StarLogic ! · O Business 90% · O Personal 41%")
            expectEqual(title(failing, format: .compact),
                        "C-A 57% · C-S ! · O-B 90% · O-P 41%")
            expectEqual(title(failing, format: .minimalLabels),
                        "A 57% · S ! · B 90% · P 41%")
        }

        test("an account that failed while holding numbers keeps them and is flagged") {
            // Losing the number would cost the user the very thing they glance
            // at. Losing the flag would let a stale number pass as current.
            let failing = [entry("C", "Claude", "Amaete", 57, error: true)]
            expectEqual(title(failing, format: .detailed), "C Amaete 57% !")
        }

        test("colliding aliases are disambiguated inside the menu bar itself") {
            let colliding = [entry("O", "OpenAI", "Business", 90),
                             entry("O", "OpenAI", "Beta", 12)]
            expectEqual(title(colliding, format: .compact),
                        "O-Bu 90% · O-Be 12%")
            expectEqual(title(colliding, format: .minimalLabels),
                        "Bu 90% · Be 12%")
        }

        test("percentages can be switched off without losing the accounts") {
            expectEqual(title(four, format: .compact, showPercentages: false),
                        "C-A · C-S · O-B · O-P")
        }

        test("only-highest keeps the worst account and never hides a failure") {
            expectEqual(title(four, format: .detailed, onlyHighest: true),
                        "O Business 90%")
            let failing = [four[0], entry("C", "Claude", "StarLogic", nil, error: true), four[2]]
            expectEqual(title(failing, format: .detailed, onlyHighest: true),
                        "C StarLogic ! · O Business 90%")
        }
    }

    suite("Summary modes stay distinct from formats") {

        test("provider mode reports the highest usage per provider") {
            expectEqual(title(four, mode: .provider),
                        "Claude 57% · OpenAI 90%")
        }

        test("provider mode flags a provider with a failing account") {
            let failing = [four[0], entry("C", "Claude", "StarLogic", nil, error: true), four[2]]
            expectEqual(title(failing, mode: .provider), "Claude 57% ! · OpenAI 90%",
                        "the provider's worst known figure survives, flagged")
        }

        test("icon-only mode is unaffected by the per-account format") {
            for format in PerAccountFormat.allCases {
                expectEqual(title(four, mode: .iconOnly, format: format), "AI")
            }
            let failing = [entry("C", "Claude", "Amaete", nil, error: true)]
            expectEqual(title(failing, mode: .iconOnly), "AI !")
        }

        test("nothing known yet means no title, so the placeholder stands") {
            expectNil(title([]))
            expectNil(title([entry("C", "Claude", "Amaete", nil)]))
        }

        test("the two “minimal” ideas are no longer both called minimal") {
            expectEqual(MenuBarSummaryMode.iconOnly.displayName, "Icon Only — just “AI”")
            expectEqual(PerAccountFormat.minimalLabels.displayName, "Minimal Labels")
            for mode in MenuBarSummaryMode.allCases {
                expect(mode.explanation.count > 20, "\\(mode.rawValue) is explained")
            }
            for format in PerAccountFormat.allCases {
                expect(format.explanation.count > 20, "\\(format.rawValue) is explained")
            }
        }

        test("entries come from enabled accounts, in order, with their aliases") {
            let store = AccountStore(defaults: scratchDefaults())
            let a = store.add(AIAccount(provider: .claude, customShortName: "Amaete",
                                        credentialSource: .appKeychain(id: "1")))
            let b = store.add(AIAccount(provider: .claude, customShortName: "StarLogic",
                                        credentialSource: .appKeychain(id: "2")))
            let c = store.add(AIAccount(provider: .openAI, customShortName: "Business",
                                        credentialSource: .appKeychain(id: "3")))
            store.setEnabled(false, id: c.id)

            var states: [UUID: AccountRuntimeState] = [:]
            for (id, pct) in [(a.id, 57.0), (b.id, 22.0)] {
                states[id] = AccountRuntimeState(usage: AccountUsage(accountID: id, metrics: [
                    UsageMetric(id: "m", name: "Weekly", usedPercent: pct, role: .weekly)]))
            }
            let entries = MenuBarLayout.sources(accounts: store.accounts, states: states)
            expectEqual(entries.count, 2, "a disabled account is absent")
            expectEqual(entries.map { $0.shortName }, ["Amaete", "StarLogic"])
            expectEqual(title(entries, format: .detailed),
                        "C Amaete 57% · C StarLogic 22%")
        }
    }

    suite("Display settings persistence") {

        test("the per-account format defaults to detailed and persists") {
            let defaults = scratchDefaults()
            expectEqual(AppSettings(defaults: defaults).perAccountFormat, .detailed)
            let s = AppSettings(defaults: defaults)
            s.perAccountFormat = .minimalLabels
            expectEqual(AppSettings(defaults: defaults).perAccountFormat, .minimalLabels)
        }

        test("the summary mode defaults to per-account and persists") {
            let defaults = scratchDefaults()
            expectEqual(AppSettings(defaults: defaults).menuBarSummaryMode, .perAccount)
            let s = AppSettings(defaults: defaults)
            s.menuBarSummaryMode = .iconOnly
            expectEqual(AppSettings(defaults: defaults).menuBarSummaryMode, .iconOnly)
        }

        test("a mode stored under the old names migrates rather than resetting") {
            expectEqual(MenuBarSummaryMode.migrating(from: "compact"), .perAccount)
            expectEqual(MenuBarSummaryMode.migrating(from: "minimal"), .iconOnly)
            expectEqual(MenuBarSummaryMode.migrating(from: "provider"), .provider)
            expectNil(MenuBarSummaryMode.migrating(from: "nonsense"))

            let defaults = scratchDefaults()
            defaults.set("compact", forKey: "display.summaryMode")
            expectEqual(AppSettings(defaults: defaults).menuBarSummaryMode, .perAccount,
                        "and existing users land on Detailed per-account, as intended")
            expectEqual(AppSettings(defaults: defaults).perAccountFormat, .detailed)
        }

        test("resetting local settings restores both display choices") {
            let s = AppSettings(defaults: scratchDefaults())
            s.menuBarSummaryMode = .iconOnly
            s.perAccountFormat = .compact
            s.resetToDefaults()
            expectEqual(s.menuBarSummaryMode, .perAccount)
            expectEqual(s.perAccountFormat, .detailed)
            expectEqual(s.backgroundOpacity, 0.95, "the opacity work is not disturbed")
        }
    }

    suite("OpenAI Business and Personal coexist") {

        test("two OpenAI accounts are saved separately, each with its own credential") {
            let store = AccountStore(defaults: scratchDefaults())
            let business = store.add(AIAccount(
                provider: .openAI,
                identity: makeIdentity(email: "work@example.com", accountID: "acct-biz", plan: "Business"),
                credentialSource: .appKeychain(id: "slot-biz")))
            let personal = store.add(AIAccount(
                provider: .openAI,
                identity: makeIdentity(email: "home@example.com", accountID: "acct-per", plan: "Plus"),
                credentialSource: .appKeychain(id: "slot-per")))

            expectEqual(store.accounts(for: .openAI).count, 2)
            expect(business.credentialSource != personal.credentialSource,
                   "adding the second must not overwrite the first")
            expectEqual(business.displayName, "OpenAI — Business (work@example.com)")
            expectEqual(personal.displayName, "OpenAI — Plus (home@example.com)")
            expectEqual(business.shortDisplayName, "Business")
            expectEqual(personal.shortDisplayName, "Plus")
        }

        test("adding the same OpenAI account again is caught, by account id") {
            let store = AccountStore(defaults: scratchDefaults())
            _ = store.add(AIAccount(provider: .openAI,
                                    identity: makeIdentity(email: "work@example.com",
                                                           accountID: "acct-biz"),
                                    credentialSource: .appKeychain(id: "slot-biz")))
            // Same account, different address on file — the id still settles it.
            expectNotNil(store.existingAccount(provider: .openAI,
                                               identity: makeIdentity(email: "renamed@example.com",
                                                                      accountID: "acct-biz")))
            // A different account is not a duplicate.
            expectNil(store.existingAccount(provider: .openAI,
                                            identity: makeIdentity(email: "home@example.com",
                                                                   accountID: "acct-per")))
        }

        test("both OpenAI accounts survive a restart with their aliases and order") {
            let defaults = scratchDefaults()
            let first = AccountStore(defaults: defaults)
            _ = first.add(AIAccount(provider: .openAI,
                                    identity: makeIdentity(email: "work@example.com",
                                                           accountID: "acct-biz", plan: "Business"),
                                    customShortName: "Business",
                                    credentialSource: .appKeychain(id: "slot-biz")))
            _ = first.add(AIAccount(provider: .openAI,
                                    identity: makeIdentity(email: "home@example.com",
                                                           accountID: "acct-per", plan: "Plus"),
                                    customShortName: "Personal",
                                    credentialSource: .appKeychain(id: "slot-per")))

            let reopened = AccountStore(defaults: defaults)
            expectEqual(reopened.accounts.map { $0.shortDisplayName }, ["Business", "Personal"])
            expectEqual(reopened.accounts.map { $0.credentialSource },
                        [.appKeychain(id: "slot-biz"), .appKeychain(id: "slot-per")])
        }

        test("the four-account topology renders in all three formats") {
            let store = AccountStore(defaults: scratchDefaults())
            let ids = [
                store.add(AIAccount(provider: .claude, customShortName: "Amaete",
                                    credentialSource: .appKeychain(id: "1"))).id,
                store.add(AIAccount(provider: .claude, customShortName: "StarLogic",
                                    credentialSource: .appKeychain(id: "2"))).id,
                store.add(AIAccount(provider: .openAI, customShortName: "Business",
                                    credentialSource: .appKeychain(id: "3"))).id,
                store.add(AIAccount(provider: .openAI, customShortName: "Personal",
                                    credentialSource: .appKeychain(id: "4"))).id,
            ]
            var states: [UUID: AccountRuntimeState] = [:]
            for (id, pct) in zip(ids, [57.0, 22.0, 90.0, 41.0]) {
                states[id] = AccountRuntimeState(usage: AccountUsage(accountID: id, metrics: [
                    UsageMetric(id: "m", name: "Weekly", usedPercent: pct, role: .weekly)]))
            }
            let entries = MenuBarLayout.sources(accounts: store.accounts, states: states)
            expectEqual(title(entries, format: .detailed),
                        "C Amaete 57% · C StarLogic 22% · O Business 90% · O Personal 41%")
            expectEqual(title(entries, format: .compact),
                        "C-A 57% · C-S 22% · O-B 90% · O-P 41%")
            expectEqual(title(entries, format: .minimalLabels),
                        "A 57% · S 22% · B 90% · P 41%")
        }
    }
}
