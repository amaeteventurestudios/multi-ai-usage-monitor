import Foundation

func runIdentityTests() {
    suite("Account identity — discovery") {

        test("a Claude profile response names the account, not just the plan") {
            let identity = ClaudeIdentityParser.parse(fixture("claude-profile.sample.json"))
            expectEqual(identity.email, "user@example.com")
            expectEqual(identity.providerAccountID, "00000000-0000-4000-8000-00000000aaaa")
            expectEqual(identity.organizationName, "Example Org")
            expectEqual(identity.planLabel, "Pro")
            expect(identity.verified, "the provider said so")
            expect(identity.isIdentified)
        }

        test("a Claude plan is read from the organisation, or from the account flags") {
            expectEqual(ClaudeIdentityParser.planLabel("claude_pro"), "Pro")
            expectEqual(ClaudeIdentityParser.planLabel("claude_max"), "Max")
            expectNil(ClaudeIdentityParser.planLabel("some_future_tier"),
                      "an unrecognised tier is not renamed to something plausible")

            var obj = fixture("claude-profile.sample.json")
            var account = obj["account"] as! [String: Any]
            account["has_claude_max"] = true
            account["has_claude_pro"] = false
            obj["account"] = account
            obj["organization"] = ["name": "Example Org"]
            expectEqual(ClaudeIdentityParser.parse(obj).planLabel, "Max")
        }

        test("an unreadable profile yields an unverified identity, never a guess") {
            let creds = ClaudeCredentials(accessToken: "t", refreshToken: nil, expiresAt: nil,
                                          scopes: nil, subscriptionType: "pro", rateLimitTier: nil)
            let identity = ClaudeIdentityParser.unidentified(credentials: creds)
            expectNil(identity.email)
            expectNil(identity.providerAccountID)
            expect(!identity.verified)
            expect(!identity.isIdentified)
            expectEqual(identity.planLabel, "Pro", "the plan is still real information")
        }

        test("an OpenAI credential names itself from its id token, with no network") {
            let path = (ProcessInfo.processInfo.environment["FIXTURES_DIR"] ?? "Tests/Fixtures")
                + "/codex-auth.sample.json"
            let auth = CodexCredentialStore.parse(data: FileManager.default.contents(atPath: path)!)!
            let identity = OpenAIIdentityParser.fromCredential(auth)
            expectEqual(identity.email, "user@example.com")
            expectEqual(identity.providerAccountID, "00000000-0000-4000-8000-000000000000")
            expectEqual(identity.planLabel, "Plus")
            expect(identity.verified)
        }

        test("the usage response wins over the credential, and fills gaps from it") {
            let fallback = makeIdentity(email: "stale@example.com", accountID: "acct-1", plan: "Plus")
            let identity = OpenAIIdentityParser.fromUsage(fixture("openai-usage.sample.json"),
                                                          fallback: fallback)
            expectEqual(identity.email, "user@example.com", "the provider's word wins")
            expectEqual(identity.planLabel, "Business")
            expectEqual(identity.planRaw, "self_serve_business_prolite",
                        "the raw identifier stays available for diagnostics")

            let sparse = OpenAIIdentityParser.fromUsage([:], fallback: fallback)
            expectEqual(sparse.email, "stale@example.com", "gaps fall back to the credential")
            expectEqual(sparse.providerAccountID, "acct-1")
        }
    }

    suite("Account identity — naming") {

        test("an identified account is named after the account, not a counter") {
            let identity = makeIdentity(email: "user@example.com", plan: "Pro")
            expectEqual(AccountNaming.displayName(provider: .claude, identity: identity, custom: nil),
                        "Claude (user@example.com)")
        }

        test("an OpenAI account carries its plan, which is what tells two apart") {
            let business = makeIdentity(email: "work@example.com", plan: "Business")
            let plus = makeIdentity(email: "home@example.com", plan: "Plus")
            expectEqual(AccountNaming.displayName(provider: .openAI, identity: business, custom: nil),
                        "OpenAI — Business (work@example.com)")
            expectEqual(AccountNaming.displayName(provider: .openAI, identity: plus, custom: nil),
                        "OpenAI — Plus (home@example.com)")
        }

        test("an OpenAI account with no known plan still leads with the e-mail") {
            let identity = makeIdentity(email: "user@example.com")
            expectEqual(AccountNaming.displayName(provider: .openAI, identity: identity, custom: nil),
                        "OpenAI (user@example.com)")
        }

        test("an unidentified account says so rather than inventing a number") {
            expectEqual(AccountNaming.displayName(provider: .claude, identity: nil, custom: nil),
                        "Claude (Unidentified account)")
            let unverified = makeIdentity(plan: "Pro", verified: false)
            expectEqual(AccountNaming.displayName(provider: .openAI, identity: unverified, custom: nil),
                        "OpenAI (Unidentified account)")
        }

        test("a name the user typed always wins") {
            let identity = makeIdentity(email: "user@example.com", plan: "Pro")
            expectEqual(AccountNaming.displayName(provider: .claude, identity: identity,
                                                  custom: "Work Claude"), "Work Claude")
            expectEqual(AccountNaming.displayName(provider: .claude, identity: identity,
                                                  custom: "   "), "Claude (user@example.com)",
                        "whitespace is not a name")
        }

        test("the plan is secondary metadata, never the identity") {
            let identity = makeIdentity(email: "user@example.com", plan: "Pro")
            expectEqual(identity.subtitle, "Plan: Pro")
            let withOrg = AccountIdentity(email: "user@example.com", organizationName: "Example Org",
                                          planLabel: "Max", verified: true)
            expectEqual(withOrg.subtitle, "Plan: Max · Example Org")
            expectNil(makeIdentity(email: "user@example.com").subtitle)
        }

        test("names this app generated for itself give way to a real identity") {
            for auto in ["Claude Account 1", "OpenAI Account 12", "Claude (pro)",
                         "OpenAI (Self Serve Business Prolite)", "Claude (Unidentified account)", "  "] {
                expect(AccountNaming.isAutoGenerated(auto), "\(auto) should be treated as generated")
            }
            for chosen in ["Work Claude", "Claude (user@example.com)", "Side project", "Home"] {
                expect(!AccountNaming.isAutoGenerated(chosen), "\(chosen) should be kept")
            }
        }
    }

    suite("Account identity — matching and duplicates") {

        test("a stable provider id settles whether two accounts are the same") {
            let a = makeIdentity(email: "old@example.com", accountID: "acct-1")
            let b = makeIdentity(email: "new@example.com", accountID: "ACCT-1")
            expect(a.matches(b), "the id wins over a changed e-mail, case-insensitively")
        }

        test("without an id, the e-mail decides") {
            expect(makeIdentity(email: "user@example.com").matches(makeIdentity(email: "USER@example.com")))
            expect(!makeIdentity(email: "a@example.com").matches(makeIdentity(email: "b@example.com")))
        }

        test("two identities with nothing comparable are treated as different") {
            expect(!makeIdentity(plan: "Pro", verified: false)
                .matches(makeIdentity(plan: "Pro", verified: false)),
                   "merging two unknown accounts would be the worse mistake")
        }

        test("a saved account with the same identity is found before a duplicate is created") {
            let store = AccountStore(defaults: scratchDefaults())
            let identity = makeIdentity(email: "user@example.com", accountID: "acct-1")
            _ = store.add(AIAccount(provider: .claude, identity: identity,
                                    credentialSource: .appKeychain(id: "k1")))

            expectNotNil(store.existingAccount(provider: .claude,
                                               identity: makeIdentity(accountID: "acct-1")),
                         "same account, recognised")
            expectNil(store.existingAccount(provider: .openAI,
                                            identity: makeIdentity(accountID: "acct-1")),
                      "the same id on another provider is a different account")
            expectNil(store.existingAccount(provider: .claude,
                                            identity: makeIdentity(email: "other@example.com")))
        }

        test("an account is not treated as a duplicate of itself when reconnecting") {
            let store = AccountStore(defaults: scratchDefaults())
            let identity = makeIdentity(email: "user@example.com", accountID: "acct-1")
            let a = store.add(AIAccount(provider: .claude, identity: identity,
                                        credentialSource: .appKeychain(id: "k1")))
            expectNil(store.existingAccount(provider: .claude, identity: identity, excluding: a.id))
        }
    }

    suite("Account persistence and credential replacement") {

        test("identity, custom name and captured credential all survive a restart") {
            let defaults = scratchDefaults()
            let first = AccountStore(defaults: defaults)
            let saved = first.add(AIAccount(
                provider: .claude,
                customDisplayName: "Work Claude",
                identity: makeIdentity(email: "work@example.com", accountID: "acct-9", plan: "Max"),
                credentialSource: .appKeychain(id: "slot-9"),
                resetOverrides: ResetOverrides(preferProviderReset: true,
                                               weekly: WeeklyResetRule(weekday: 2, hour: 7, minute: 0)),
                notificationThresholdPercent: 80))

            let reopened = AccountStore(defaults: defaults)
            let account = reopened.account(id: saved.id)
            expectNotNil(account)
            expectEqual(account?.displayName, "Work Claude")
            expectEqual(account?.identity?.email, "work@example.com")
            expectEqual(account?.identity?.providerAccountID, "acct-9")
            expectEqual(account?.credentialSource, .appKeychain(id: "slot-9"))
            expectEqual(account?.resetOverrides.weekly?.hour, 7)
            expectEqual(account?.notificationThresholdPercent, 80)
            expect(account?.hasCapturedCredential == true)
        }

        test("an account stored by the previous version loads and can still be identified") {
            // The old shape: one displayName string, no identity.
            let json = """
            [{"id":"00000000-0000-4000-8000-000000000001","provider":"claude",
              "displayName":"Claude (pro)","enabled":true,"order":0,
              "credentialSource":{"kind":"claudeCodeKeychain"},
              "resetOverrides":{"preferProviderReset":true}}]
            """
            let defaults = scratchDefaults()
            defaults.set(Data(json.utf8), forKey: "accounts.v1")
            let store = AccountStore(defaults: defaults)
            expectEqual(store.accounts.count, 1)
            let account = store.accounts[0]
            expectNil(account.customDisplayName,
                      "a name this app generated does not outlive identity detection")
            expectEqual(account.displayName, "Claude (Unidentified account)")

            store.setIdentity(makeIdentity(email: "user@example.com", plan: "Pro"), id: account.id)
            expectEqual(store.accounts[0].displayName, "Claude (user@example.com)")
        }

        test("a name the user chose in the previous version is kept") {
            let json = """
            [{"id":"00000000-0000-4000-8000-000000000002","provider":"claude",
              "displayName":"Side project","enabled":true,"order":0,
              "credentialSource":{"kind":"claudeCodeKeychain"},
              "resetOverrides":{"preferProviderReset":true}}]
            """
            let defaults = scratchDefaults()
            defaults.set(Data(json.utf8), forKey: "accounts.v1")
            expectEqual(AccountStore(defaults: defaults).accounts[0].displayName, "Side project")
        }

        test("replacing a credential changes only the credential") {
            let store = AccountStore(defaults: scratchDefaults())
            let saved = store.add(AIAccount(
                provider: .claude,
                customDisplayName: "Work Claude",
                identity: makeIdentity(email: "work@example.com", accountID: "acct-9"),
                credentialSource: .claudeCodeKeychain,
                resetOverrides: ResetOverrides(preferProviderReset: false,
                                               weekly: WeeklyResetRule(weekday: 2, hour: 2, minute: 0)),
                notificationThresholdPercent: 75))
            _ = store.add(makeAccount(.claude, name: "Other"))
            store.move(id: saved.id, by: 1)

            store.setCredentialSource(.appKeychain(id: "fresh"), id: saved.id)

            let after = store.account(id: saved.id)
            expectEqual(after?.credentialSource, .appKeychain(id: "fresh"))
            expectEqual(after?.displayName, "Work Claude", "the name survives a reconnect")
            expectEqual(after?.resetOverrides.weekly?.hour, 2, "and so does the reset rule")
            expectEqual(after?.resetOverrides.preferProviderReset, false)
            expectEqual(after?.notificationThresholdPercent, 75)
            expectEqual(after?.order, 1, "and its position in the list")
            expectEqual(after?.identity?.email, "work@example.com")
        }

        test("a captured credential is what makes an account independent") {
            let borrowed = AIAccount(provider: .claude, credentialSource: .claudeCodeKeychain)
            let owned = AIAccount(provider: .claude, credentialSource: .appKeychain(id: "slot"))
            expect(!borrowed.hasCapturedCredential,
                   "reading another tool's single slot is not independence")
            expect(owned.hasCapturedCredential)
        }

        test("an imported credential is a valid source for either provider") {
            expect(CredentialSource.appKeychain(id: "x").isValid(for: .claude))
            expect(CredentialSource.appKeychain(id: "x").isValid(for: .openAI))
        }
    }

    suite("Onboarding copy names the tool, not the brand") {

        test("every provider offers a primary method that resolves an account first") {
            for provider in ProviderKind.allCases {
                let methods = ProviderRegistry.provider(for: provider).credentialMethods()
                let primary = methods.first { $0.isPrimary }
                expectNotNil(primary, "\(provider.displayName) has an everyday path")
                expect(primary?.supportsPreflight == true,
                       "\(provider.displayName)'s primary method can be checked before committing")
                expectNotNil(primary?.preflightHeading,
                             "\(provider.displayName) says whose account it is showing")
                expectNotNil(primary?.switchInstruction,
                             "\(provider.displayName) says what to do if it is the wrong one")
                expectNotNil(primary?.disclaimer,
                             "\(provider.displayName) says what the credential actually is")
            }
        }

        test("Claude's heading and instruction name Claude Code exactly") {
            let primary = ProviderRegistry.claude.credentialMethods().first { $0.isPrimary }!
            expectEqual(primary.title, "Import the current Claude Code account")
            expectEqual(primary.preflightHeading, "Current Claude Code account")
            expect(primary.switchInstruction?.contains("Switch Claude Code") == true,
                   "got \(primary.switchInstruction ?? "nil")")
            expect(primary.switchInstruction?.contains("Check Again") == true)
        }

        test("Claude's disclaimer warns that the browser and desktop logins may differ") {
            let disclaimer = ProviderRegistry.claude.credentialMethods()
                .first { $0.isPrimary }!.disclaimer!
            expect(disclaimer.contains("Claude Code's terminal/CLI credential"))
            expect(disclaimer.contains("browser"))
            expect(disclaimer.contains("desktop-app"))
        }

        test("OpenAI's copy names Codex/OpenAI tooling, not the ChatGPT brand") {
            let primary = ProviderRegistry.openAI.credentialMethods().first { $0.isPrimary }!
            expectEqual(primary.title, "Import the current Codex/OpenAI account")
            expectEqual(primary.preflightHeading, "Current ChatGPT app / Codex CLI account")
            expect(primary.disclaimer?.contains("Codex/OpenAI tooling on this Mac") == true)
            expect(primary.disclaimer?.contains("ChatGPT browser session") == true,
                   "and warns a browser session may be a different account")
            expect(primary.switchInstruction?.contains("Check Again") == true)
        }

        test("each method says where it reads from") {
            expect(ProviderRegistry.openAI.credentialMethods().first { $0.isPrimary }!
                .sourceSummary.contains("~/.codex/auth.json"))
            expect(ProviderRegistry.claude.credentialMethods().first { $0.isPrimary }!
                .sourceSummary.contains("Claude Code"))
        }

        test("no method copy implies we read the plain Claude or ChatGPT session") {
            // The credential is a specific tool's sign-in. Softening "Claude Code"
            // to "Claude" would point at claude.ai in a browser, which is a
            // different login and could be a different account entirely.
            for provider in ProviderKind.allCases {
                for method in ProviderRegistry.provider(for: provider).credentialMethods() {
                    let copy = [method.title, method.detail, method.preflightHeading,
                                method.switchInstruction].compactMap { $0 }.joined(separator: " ")
                    expect(!copy.contains("Claude is signed in"),
                           "\(provider.displayName): “Claude is signed in” means Claude Code here")
                    expect(!copy.contains("ChatGPT is signed in"),
                           "\(provider.displayName): name the app or the CLI, not the brand")
                    expect(!copy.contains("Sign in to Claude "),
                           "\(provider.displayName): sign-in happens in a named tool")
                }
            }
        }

        test("a file-based method is an advanced fallback, not a preflight one") {
            for provider in ProviderKind.allCases {
                let file = ProviderRegistry.provider(for: provider).credentialMethods()
                    .first { $0.requiresFileChoice }
                expectNotNil(file, "\(provider.displayName) keeps a file fallback")
                expect(file?.isPrimary == false)
                expect(file?.supportsPreflight == false,
                       "nothing can be resolved until a file is chosen")
            }
        }
    }

    suite("Keychain output decoding") {

        test("a hex-encoded multi-line value is decoded back to its text") {
            let original = "{\n  \"tokens\": {\n    \"access_token\": \"x\"\n  }\n}"
            let hex = original.utf8.map { String(format: "%02x", $0) }.joined()
            expectEqual(Keychain.decodeSecurityOutput(hex), original,
                        "security hex-encodes anything containing a newline")
        }

        test("plain text is returned untouched") {
            let json = "{\"claudeAiOauth\":{\"accessToken\":\"not-a-real-token\"}}"
            expectEqual(Keychain.decodeSecurityOutput(json), json)
        }

        test("a value that merely looks like hex is not mangled") {
            // Even-length, all lowercase hex, but it decodes to printable text
            // with no control characters — so it is a real password, not an
            // encoding of one.
            expectEqual(Keychain.decodeSecurityOutput("deadbeef"), "deadbeef")
            expectEqual(Keychain.decodeSecurityOutput("abc"), "abc", "odd length is never hex")
            expectEqual(Keychain.decodeSecurityOutput("DEADBEEF"), "DEADBEEF",
                        "security emits lowercase; uppercase is someone's password")
            expectEqual(Keychain.decodeSecurityOutput(""), "")
        }

        test("hex that does not decode to valid text is left alone") {
            expectEqual(Keychain.decodeSecurityOutput("fffefdfc"), "fffefdfc")
        }
    }

}
