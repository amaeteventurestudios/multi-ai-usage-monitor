import Foundation

func runParsingTests() {
    let cal = calendar("America/New_York")
    let now = date(2026, 6, 15, 9, 0, in: cal)

    suite("Claude response parsing") {

        test("the three usage windows are parsed with used percentages") {
            let account = makeAccount(.claude)
            let usage = try ClaudeUsageParser.parse(fixture("claude-usage.sample.json"),
                                                    account: account, now: now, calendar: cal)
            let ids = usage.metrics.map { $0.id }
            expect(ids.contains("claude.session"))
            expect(ids.contains("claude.weekly_all"))
            expect(ids.contains("claude.weekly_scoped"))

            let session = usage.metrics.first { $0.id == "claude.session" }!
            expectEqual(session.usedPercent, 12)
            expectEqual(session.state, .available)
            expect(session.resetFromProvider, "the API supplied this reset")
            expectEqual(session.windowDescription, "5-hour")

            let scoped = usage.metrics.first { $0.id == "claude.weekly_scoped" }!
            expectEqual(scoped.name, "Weekly (Opus)")
            expectEqual(scoped.usedPercent, 61)
        }

        test("the plan is reported as a label, not invented") {
            let usage = try ClaudeUsageParser.parse(fixture("claude-usage.sample.json"),
                                                    account: makeAccount(.claude), now: now, calendar: cal)
            expectEqual(usage.accountLabel, "plan: max")
        }

        test("spend credits become a money metric") {
            let usage = try ClaudeUsageParser.parse(fixture("claude-usage.sample.json"),
                                                    account: makeAccount(.claude), now: now, calendar: cal)
            let credit = usage.metrics.first { $0.id == "claude.credits" }
            expectNotNil(credit)
            expectEqual(credit?.usedPercent, 9)
            expect(credit?.detail?.contains("4.29") == true, "formatted from minor units")
        }

        test("the newer limits[] shape parses the same way") {
            let usage = try ClaudeUsageParser.parse(fixture("claude-usage-limits-array.sample.json"),
                                                    account: makeAccount(.claude), now: now, calendar: cal)
            expectEqual(usage.metrics.count, 3)
            expectEqual(usage.metrics.first { $0.id == "claude.session" }?.usedPercent, 5)
            expectEqual(usage.metrics.first { $0.id == "claude.weekly_scoped" }?.name, "Weekly (Sonnet)")
            expectEqual(usage.accountLabel, "plan: default")
        }

        test("fractional-second timestamps parse") {
            let usage = try ClaudeUsageParser.parse(fixture("claude-usage-limits-array.sample.json"),
                                                    account: makeAccount(.claude), now: now, calendar: cal)
            expectNotNil(usage.metrics.first { $0.id == "claude.session" }?.resetsAt)
        }

        test("a 200 with no windows is a parse failure, not a confident 0%") {
            var threw = false
            do {
                _ = try ClaudeUsageParser.parse(fixture("claude-usage-empty.sample.json"),
                                                account: makeAccount(.claude), now: now, calendar: cal)
            } catch { threw = true }
            expect(threw, "an empty response must not overwrite good numbers with zeroes")
        }

        test("a local weekly rule fills in only when the provider gives no reset") {
            let rule = WeeklyResetRule(weekday: 2, hour: 2, minute: 0)
            let account = makeAccount(.claude, weekly: rule)
            let usage = try ClaudeUsageParser.parse(fixture("claude-usage.sample.json"),
                                                    account: account, now: now, calendar: cal)
            let weekly = usage.metrics.first { $0.id == "claude.weekly_all" }!
            expect(weekly.resetFromProvider, "the provider's value still wins")

            var stripped = fixture("claude-usage.sample.json")
            stripped["seven_day"] = ["percent": 43]
            let fallback = try ClaudeUsageParser.parse(stripped, account: account, now: now, calendar: cal)
            let weeklyFallback = fallback.metrics.first { $0.id == "claude.weekly_all" }!
            expect(!weeklyFallback.resetFromProvider, "and the local rule is labelled as local")
            expectEqual(components(weeklyFallback.resetsAt!, in: cal).hour, 2)
        }

        test("a weekly rule is never applied to the rolling session window") {
            var stripped = fixture("claude-usage.sample.json")
            stripped["five_hour"] = ["percent": 12]
            let account = makeAccount(.claude, weekly: WeeklyResetRule(weekday: 2, hour: 2, minute: 0))
            let usage = try ClaudeUsageParser.parse(stripped, account: account, now: now, calendar: cal)
            let session = usage.metrics.first { $0.id == "claude.session" }!
            expectNil(session.resetsAt, "a weekly schedule says nothing about a 5-hour window")
        }

        test("legacy extra_usage credits still parse") {
            let obj: [String: Any] = [
                "five_hour": ["percent": 1],
                "extra_usage": ["is_enabled": true, "monthly_limit": 2000,
                                "used_credits": 500, "currency": "USD", "decimal_places": 2],
            ]
            let usage = try ClaudeUsageParser.parse(obj, account: makeAccount(.claude),
                                                    now: now, calendar: cal)
            expectEqual(usage.metrics.first { $0.id == "claude.credits" }?.usedPercent, 25)
        }
    }

    suite("OpenAI response parsing") {

        test("windows are named from the length the provider reports") {
            let usage = try OpenAIUsageParser.parse(fixture("openai-usage.sample.json"),
                                                    account: makeAccount(.openAI), now: now, calendar: cal)
            let primary = usage.metrics.first { $0.id == "openai.primary" }!
            expectEqual(primary.name, "Codex Weekly", "604800s is a week")
            expectEqual(primary.usedPercent, 89)

            let secondary = usage.metrics.first { $0.id == "openai.secondary" }!
            expectEqual(secondary.name, "Codex 5-hour", "18000s, read from the response")
            expectEqual(secondary.usedPercent, 22)
        }

        test("metrics are named Codex, because that is what this endpoint measures") {
            let usage = try OpenAIUsageParser.parse(fixture("openai-usage.sample.json"),
                                                    account: makeAccount(.openAI), now: now, calendar: cal)
            let named = usage.metrics.filter { $0.usedPercent != nil }
            expect(named.allSatisfy { $0.name.hasPrefix("Codex") },
                   "no generic “ChatGPT Weekly” that could mean either product")
        }

        test("ChatGPT message allowance is present but honestly unavailable") {
            let usage = try OpenAIUsageParser.parse(fixture("openai-usage.sample.json"),
                                                    account: makeAccount(.openAI), now: now, calendar: cal)
            let pro = usage.metrics.first { $0.id == "openai.pro_messages" }!
            expectEqual(pro.state, .unsupported)
            expectNil(pro.usedPercent, "no fabricated number")
            expectNil(pro.usedCount)
            expectNotNil(pro.detail, "and an explanation of why")
        }

        test("the reset timestamp comes from the provider") {
            let usage = try OpenAIUsageParser.parse(fixture("openai-usage.sample.json"),
                                                    account: makeAccount(.openAI), now: now, calendar: cal)
            let primary = usage.metrics.first { $0.id == "openai.primary" }!
            expect(primary.resetFromProvider)
            expectEqual(primary.resetsAt, Date(timeIntervalSince1970: 1789951159))
        }

        test("reset_after_seconds is used when reset_at is absent") {
            var obj = fixture("openai-usage.sample.json")
            var rl = obj["rate_limit"] as! [String: Any]
            rl["primary_window"] = ["used_percent": 50, "limit_window_seconds": 604800,
                                    "reset_after_seconds": 3600]
            obj["rate_limit"] = rl
            let usage = try OpenAIUsageParser.parse(obj, account: makeAccount(.openAI),
                                                    now: now, calendar: cal)
            let primary = usage.metrics.first { $0.id == "openai.primary" }!
            expectEqual(primary.resetsAt, now.addingTimeInterval(3600))
        }

        test("the account label carries the e-mail and a readable plan name") {
            let usage = try OpenAIUsageParser.parse(fixture("openai-usage.sample.json"),
                                                    account: makeAccount(.openAI), now: now, calendar: cal)
            expectEqual(usage.accountLabel, "user@example.com · plan: Self Serve Business Prolite")
        }

        test("known plan identifiers get their proper names, unknown ones are title-cased") {
            expectEqual(OpenAIUsageParser.planDisplayName("plus"), "Plus")
            expectEqual(OpenAIUsageParser.planDisplayName("pro"), "Pro")
            expectEqual(OpenAIUsageParser.planDisplayName("some_new_plan"), "Some New Plan")
        }

        test("a credit balance with no cap becomes a note, not a bar") {
            let usage = try OpenAIUsageParser.parse(fixture("openai-usage.sample.json"),
                                                    account: makeAccount(.openAI), now: now, calendar: cal)
            expect(usage.notes.contains { $0.hasPrefix("Credits:") })
            expect(!usage.metrics.contains { $0.name.contains("Credits") })
        }

        test("models the provider marks unavailable are reported as such") {
            let usage = try OpenAIUsageParser.parse(fixture("openai-usage.sample.json"),
                                                    account: makeAccount(.openAI), now: now, calendar: cal)
            expect(usage.notes.contains { $0.contains("example-model-b") })
            expect(!usage.notes.contains { $0.contains("example-model-a") })
        }

        test("a 200 with no windows is a parse failure") {
            var threw = false
            do {
                _ = try OpenAIUsageParser.parse(fixture("openai-usage-empty.sample.json"),
                                                account: makeAccount(.openAI), now: now, calendar: cal)
            } catch { threw = true }
            expect(threw)
        }

        test("additional windows appear without a code change") {
            var obj = fixture("openai-usage.sample.json")
            obj["additional_rate_limits"] = [["used_percent": 7, "limit_window_seconds": 86400,
                                              "reset_after_seconds": 600]]
            let usage = try OpenAIUsageParser.parse(obj, account: makeAccount(.openAI),
                                                    now: now, calendar: cal)
            expectEqual(usage.metrics.first { $0.id == "openai.extra0" }?.name, "Codex Daily")
        }

        test("window labels follow the seconds the provider sends") {
            expectEqual(Fmt.windowLabel(18000), "5-hour")
            expectEqual(Fmt.windowLabel(604800), "Weekly")
            expectEqual(Fmt.windowLabel(86400), "Daily")
            expectEqual(Fmt.windowLabel(2592000), "Monthly")
            expectEqual(Fmt.windowLabel(1800), "30-minute")
            expectEqual(Fmt.windowLabel(-1), "Usage")
        }
    }

    suite("Credential parsing") {

        test("a Claude credential parses from the wrapper shape") {
            let path = (ProcessInfo.processInfo.environment["FIXTURES_DIR"] ?? "Tests/Fixtures")
                + "/claude-credential.sample.json"
            let data = FileManager.default.contents(atPath: path)!
            let creds = ClaudeCredentials.parse(data: data)
            expectNotNil(creds)
            expectEqual(creds?.subscriptionType, "max")
            expect(creds?.isExpired == false, "the sample expiry is far in the future")
        }

        test("a bare credential object parses too") {
            let json = #"{"accessToken":"not-a-real-token","expiresAt":4102444800000}"#
            expectNotNil(ClaudeCredentials.parse(json: json))
        }

        test("an empty or malformed credential is rejected") {
            expectNil(ClaudeCredentials.parse(json: "{}"))
            expectNil(ClaudeCredentials.parse(json: #"{"claudeAiOauth":{"accessToken":""}}"#))
            expectNil(ClaudeCredentials.parse(json: "not json"))
        }

        test("a credential re-serialises into the shape Claude Code expects") {
            let creds = ClaudeCredentials(accessToken: "not-a-real-token",
                                          refreshToken: "not-a-real-refresh",
                                          expiresAt: 4102444800000, scopes: ["user:inference"],
                                          subscriptionType: "max", rateLimitTier: nil)
            let json = creds.serialized()!
            expect(json.contains("claudeAiOauth"))
            expectEqual(ClaudeCredentials.parse(json: json), creds)
        }

        test("an expired credential is recognised") {
            let creds = ClaudeCredentials(accessToken: "t", refreshToken: nil,
                                          expiresAt: 1_000_000_000_000, scopes: nil,
                                          subscriptionType: nil, rateLimitTier: nil)
            expect(creds.isExpired)
        }

        test("a Codex auth file parses to a token, account id and expiry") {
            let path = (ProcessInfo.processInfo.environment["FIXTURES_DIR"] ?? "Tests/Fixtures")
                + "/codex-auth.sample.json"
            let data = FileManager.default.contents(atPath: path)!
            let auth = CodexCredentialStore.parse(data: data)
            expectNotNil(auth)
            expectEqual(auth?.accountId, "00000000-0000-4000-8000-000000000000")
            expect(auth?.isExpired == false)
        }

        test("the plan and e-mail hint come from the id token, without verifying it") {
            let path = (ProcessInfo.processInfo.environment["FIXTURES_DIR"] ?? "Tests/Fixtures")
                + "/codex-auth.sample.json"
            let hint = CodexCredentialStore.identityHint(source: .file(path: path))
            expectEqual(hint.email, "user@example.com")
            expectEqual(hint.plan, "plus")
        }

        test("validating a credential path reports why it cannot be used") {
            switch CodexCredentialStore.validate(path: "/nonexistent/auth.json") {
            case .success: expect(false, "a missing file must not validate")
            case .failure(let e): expectEqual(e.kind, .invalidPath)
            }
            let notJSON = NSTemporaryDirectory() + "/maum-test-\(UUID().uuidString).json"
            try "definitely not json".write(toFile: notJSON, atomically: true, encoding: .utf8)
            switch CodexCredentialStore.validate(path: notJSON) {
            case .success: expect(false, "invalid JSON must not validate")
            case .failure(let e): expect(e.message.contains("JSON"))
            }
            try? FileManager.default.removeItem(atPath: notJSON)
        }

        test("a valid Codex file validates") {
            let path = (ProcessInfo.processInfo.environment["FIXTURES_DIR"] ?? "Tests/Fixtures")
                + "/codex-auth.sample.json"
            switch CodexCredentialStore.validate(path: path) {
            case .success: expect(true)
            case .failure(let e): expect(false, "should have validated: \(e.message)")
            }
        }
    }
}
