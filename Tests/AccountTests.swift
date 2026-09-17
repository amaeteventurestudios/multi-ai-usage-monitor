import Foundation

func runAccountTests() {
    suite("Accounts — model and storage") {

        test("an account round-trips through JSON with every credential source") {
            let sources: [CredentialSource] = [
                .claudeCodeKeychain,
                .appKeychain(id: "6E2B0C5A-0000-4000-8000-000000000001"),
                .file(path: "/Users/example/.codex/auth.json"),
                .codexDefault,
            ]
            for source in sources {
                let original = AIAccount(provider: source == .codexDefault ? .openAI : .claude,
                                         customDisplayName: "Example",
                                         enabled: false,
                                         order: 3,
                                         credentialSource: source,
                                         resetOverrides: ResetOverrides(
                                            preferProviderReset: false,
                                            weekly: WeeklyResetRule(weekday: 2, hour: 7, minute: 0)),
                                         notificationThresholdPercent: 75)
                let data = try JSONEncoder().encode(original)
                let decoded = try JSONDecoder().decode(AIAccount.self, from: data)
                expectEqual(decoded, original, "round-trip for \(source.kindLabel)")
            }
        }

        test("an unknown credential source in stored data is rejected, not guessed at") {
            let json = """
            {"id":"6E2B0C5A-0000-4000-8000-000000000001","provider":"claude",
             "displayName":"X","enabled":true,"order":0,
             "credentialSource":{"kind":"martian"},
             "resetOverrides":{"preferProviderReset":true}}
            """
            let decoded = try? JSONDecoder().decode(AIAccount.self, from: Data(json.utf8))
            expectNil(decoded)
        }

        test("two accounts on the same provider coexist independently") {
            let store = AccountStore(defaults: scratchDefaults())
            let a = store.add(AIAccount(provider: .claude, customDisplayName: "Personal Claude",
                                        credentialSource: .claudeCodeKeychain))
            let b = store.add(AIAccount(provider: .claude, customDisplayName: "Work Claude",
                                        credentialSource: .appKeychain(id: UUID().uuidString)))
            expectEqual(store.accounts(for: .claude).count, 2)
            expect(a.id != b.id, "distinct identities")
            expect(a.credentialSource != b.credentialSource,
                   "the second account must not share the first's credential")
        }

        test("adding a second Claude account leaves the first's credential source alone") {
            let store = AccountStore(defaults: scratchDefaults())
            let first = store.add(AIAccount(provider: .claude, customDisplayName: "One",
                                            credentialSource: .claudeCodeKeychain))
            _ = store.add(AIAccount(provider: .claude, customDisplayName: "Two",
                                    credentialSource: .appKeychain(id: UUID().uuidString)))
            expectEqual(store.account(id: first.id)?.credentialSource, .claudeCodeKeychain)
        }

        test("badges number accounts only when a provider has more than one") {
            let store = AccountStore(defaults: scratchDefaults())
            let solo = store.add(AIAccount(provider: .openAI, customDisplayName: "Business",
                                           credentialSource: .codexDefault))
            expectEqual(store.badge(for: solo), "G")

            let c1 = store.add(AIAccount(provider: .claude, customDisplayName: "One",
                                         credentialSource: .claudeCodeKeychain))
            let c2 = store.add(AIAccount(provider: .claude, customDisplayName: "Two",
                                         credentialSource: .appKeychain(id: "x")))
            expectEqual(store.badge(for: c1), "C1")
            expectEqual(store.badge(for: c2), "C2")
            expectEqual(store.badge(for: solo), "G", "the single OpenAI account stays unnumbered")
        }

        test("ordering survives a move and is renumbered contiguously") {
            let store = AccountStore(defaults: scratchDefaults())
            let a = store.add(makeAccount(.claude, name: "A"))
            let b = store.add(makeAccount(.claude, name: "B"))
            let c = store.add(makeAccount(.claude, name: "C"))
            store.move(id: c.id, by: -1)
            expectEqual(store.accounts.map { $0.displayName }, ["A", "C", "B"])
            expectEqual(store.accounts.map { $0.order }, [0, 1, 2])
            store.move(id: a.id, by: 1)
            expectEqual(store.accounts.map { $0.displayName }, ["C", "A", "B"])
            _ = b
        }

        test("moving past either end is a no-op rather than a crash") {
            let store = AccountStore(defaults: scratchDefaults())
            let a = store.add(makeAccount(.claude, name: "A"))
            let b = store.add(makeAccount(.claude, name: "B"))
            store.move(id: a.id, by: -1)
            store.move(id: b.id, by: 5)
            expectEqual(store.accounts.map { $0.displayName }, ["A", "B"])
        }

        test("accounts persist across a restart of the store") {
            let defaults = scratchDefaults()
            let first = AccountStore(defaults: defaults)
            _ = first.add(AIAccount(provider: .claude, customDisplayName: "Personal Claude",
                                    credentialSource: .claudeCodeKeychain,
                                    resetOverrides: ResetOverrides(
                                        preferProviderReset: true,
                                        weekly: WeeklyResetRule(weekday: 2, hour: 2, minute: 0))))
            _ = first.add(AIAccount(provider: .openAI, customDisplayName: "Business Premium",
                                    credentialSource: .codexDefault))

            let reopened = AccountStore(defaults: defaults)
            expectEqual(reopened.accounts.count, 2)
            expectEqual(reopened.accounts[0].displayName, "Personal Claude")
            expectEqual(reopened.accounts[0].resetOverrides.weekly?.hour, 2)
            expectEqual(reopened.accounts[1].provider, .openAI)
        }

        test("a corrupt account list starts empty instead of wedging the app") {
            let defaults = scratchDefaults()
            defaults.set(Data("not json".utf8), forKey: "accounts.v1")
            let store = AccountStore(defaults: defaults)
            expectEqual(store.accounts.count, 0)
        }

        test("renaming sets a custom label, and clearing it restores the detected name") {
            let store = AccountStore(defaults: scratchDefaults())
            let a = store.add(makeAccount(.claude, name: "Original", email: "user@example.com"))
            expectEqual(store.account(id: a.id)?.displayName, "Original")
            store.rename(id: a.id, to: "  Renamed ")
            expectEqual(store.account(id: a.id)?.displayName, "Renamed")
            store.rename(id: a.id, to: "   ")
            expectEqual(store.account(id: a.id)?.displayName, "Claude (user@example.com)",
                        "an empty name hands naming back to the detected identity")
        }

        test("enable and disable are per account") {
            let store = AccountStore(defaults: scratchDefaults())
            let a = store.add(makeAccount(.claude, name: "A"))
            let b = store.add(makeAccount(.claude, name: "B"))
            store.setEnabled(false, id: a.id)
            expectEqual(store.enabledAccounts.map { $0.id }, [b.id])
        }

        test("credential sources are validated against their provider") {
            expect(CredentialSource.claudeCodeKeychain.isValid(for: .claude))
            expect(!CredentialSource.claudeCodeKeychain.isValid(for: .openAI))
            expect(CredentialSource.codexDefault.isValid(for: .openAI))
            expect(!CredentialSource.codexDefault.isValid(for: .claude))
            expect(CredentialSource.file(path: "/tmp/x").isValid(for: .claude))
            expect(CredentialSource.file(path: "/tmp/x").isValid(for: .openAI))
        }
    }

    suite("Settings persistence") {

        test("defaults are the documented ones") {
            let s = AppSettings(defaults: scratchDefaults())
            expectEqual(s.backgroundOpacity, 0.95)
            expectEqual(s.refreshIntervalMinutes, 5)
            expectEqual(s.menuBarSummaryMode, .compact)
            expectEqual(s.warningThresholdPercent, 90)
            expect(s.usageWarningsEnabled)
            expect(s.authWarningsEnabled)
            expect(!s.debugLogging)
            expect(!s.diagnosticsIncludeIdentities)
        }

        test("settings survive a restart") {
            let defaults = scratchDefaults()
            let first = AppSettings(defaults: defaults)
            first.refreshIntervalMinutes = 15
            first.menuBarSummaryMode = .provider
            first.warningThresholdPercent = 75
            first.onlyHighestInMenuBar = true

            let reopened = AppSettings(defaults: defaults)
            expectEqual(reopened.refreshIntervalMinutes, 15)
            expectEqual(reopened.menuBarSummaryMode, .provider)
            expectEqual(reopened.warningThresholdPercent, 75)
            expect(reopened.onlyHighestInMenuBar)
        }

        test("manual-only refresh is representable and distinct from zero minutes") {
            let s = AppSettings(defaults: scratchDefaults())
            s.refreshIntervalMinutes = nil
            expectNil(s.refreshIntervalMinutes)
            expectNil(s.refreshInterval)
            s.refreshIntervalMinutes = 10
            expectEqual(s.refreshInterval, 600)
        }

        test("an absurd interval is clamped rather than obeyed") {
            let s = AppSettings(defaults: scratchDefaults())
            s.refreshIntervalMinutes = 99999
            expectEqual(s.refreshIntervalMinutes, 120)
        }

        test("thresholds are clamped to a sane range") {
            let s = AppSettings(defaults: scratchDefaults())
            s.warningThresholdPercent = 500
            expectEqual(s.warningThresholdPercent, 100)
            s.warningThresholdPercent = -5
            expectEqual(s.warningThresholdPercent, 1)
        }

        test("background opacity persists across a restart") {
            let defaults = scratchDefaults()
            let first = AppSettings(defaults: defaults)
            first.backgroundOpacity = 0.75
            expectEqual(AppSettings(defaults: defaults).backgroundOpacity, 0.75)
        }

        test("background opacity is clamped so the app can never be made unreadable") {
            let s = AppSettings(defaults: scratchDefaults())
            s.backgroundOpacity = 0.0
            expectEqual(s.backgroundOpacity, 0.70, "the floor holds")
            s.backgroundOpacity = 5.0
            expectEqual(s.backgroundOpacity, 1.00, "and so does the ceiling")
            expectEqual(AppSettings.clampBackgroundOpacity(.nan), 0.95,
                        "a nonsense value falls back to the default")
            expectEqual(AppSettings.clampBackgroundOpacity(0.9), 0.9)
        }

        test("a value written straight into defaults out of range is still clamped on read") {
            let defaults = scratchDefaults()
            defaults.set(0.1, forKey: "display.backgroundOpacity")
            expectEqual(AppSettings(defaults: defaults).backgroundOpacity, 0.70)
        }

        test("resetting local settings restores defaults") {
            let s = AppSettings(defaults: scratchDefaults())
            s.warningThresholdPercent = 42
            s.menuBarSummaryMode = .minimal
            s.backgroundOpacity = 0.65
            s.resetToDefaults()
            expectEqual(s.warningThresholdPercent, 90)
            expectEqual(s.menuBarSummaryMode, .compact)
            expectEqual(s.backgroundOpacity, 0.95)
        }
    }

    suite("Migration from the single-provider build") {

        test("nothing to migrate when the old domain is empty") {
            expectNil(LegacySettingsSnapshot.read(from: scratchDefaults()))
        }

        test("legacy provider switches and paths become accounts") {
            let legacyDefaults = scratchDefaults()
            legacyDefaults.set(true, forKey: "provider.anthropic.enabled")
            legacyDefaults.set(false, forKey: "provider.openai.enabled")
            legacyDefaults.set(10, forKey: "refreshIntervalMinutes")
            legacyDefaults.set(85, forKey: "alertThresholdPercent")

            let legacy = LegacySettingsSnapshot.read(from: legacyDefaults)
            expectNotNil(legacy)
            expectEqual(legacy?.anthropicEnabled, true)
            expectEqual(legacy?.openAIEnabled, false)

            let accounts = LegacyMigration.accounts(
                legacy: legacy,
                detected: DetectedCredentials(claudeCodeKeychain: true, codexDefault: true))
            expectEqual(accounts.count, 2)
            expectEqual(accounts[0].provider, .claude)
            expectEqual(accounts[0].credentialSource, .claudeCodeKeychain)
            expectEqual(accounts[0].enabled, true)
            expectEqual(accounts[1].provider, .openAI)
            expectEqual(accounts[1].enabled, false, "a provider switched off stays off")

            let settings = AppSettings(defaults: scratchDefaults())
            LegacyMigration.apply(legacy: legacy, to: settings)
            expectEqual(settings.refreshIntervalMinutes, 10, "the old interval is preserved")
            expectEqual(settings.warningThresholdPercent, 85)
        }

        test("a legacy custom path becomes that account's credential source") {
            let legacyDefaults = scratchDefaults()
            legacyDefaults.set("/Users/example/.codex/auth.json", forKey: "provider.openai.path")
            let legacy = LegacySettingsSnapshot.read(from: legacyDefaults)
            let accounts = LegacyMigration.accounts(
                legacy: legacy,
                detected: DetectedCredentials(claudeCodeKeychain: false, codexDefault: false))
            expectEqual(accounts.count, 1)
            expectEqual(accounts[0].credentialSource, .file(path: "/Users/example/.codex/auth.json"))
        }

        test("no credentials on this Mac means no invented accounts") {
            let accounts = LegacyMigration.accounts(
                legacy: nil,
                detected: DetectedCredentials(claudeCodeKeychain: false, codexDefault: false))
            expectEqual(accounts.count, 0)
        }

        test("migration sets no reset override — it never invents a schedule") {
            let accounts = LegacyMigration.accounts(
                legacy: nil,
                detected: DetectedCredentials(claudeCodeKeychain: true, codexDefault: true))
            for a in accounts {
                expectNil(a.resetOverrides.weekly, "\(a.displayName) must have no baked-in schedule")
                expect(a.resetOverrides.preferProviderReset)
            }
        }

        test("migration names nothing — identity detection does that later") {
            let accounts = LegacyMigration.accounts(
                legacy: nil,
                detected: DetectedCredentials(claudeCodeKeychain: true, codexDefault: true))
            for a in accounts {
                expectNil(a.customDisplayName, "no counter name is baked in")
                expectNil(a.identity, "identity is discovered from the provider, not assumed")
                expect(a.displayName.hasSuffix(AccountNaming.unidentifiedSuffix),
                       "until then it says so plainly, got \(a.displayName)")
            }
        }
    }
}
