import Foundation

func runBehaviourTests() {
    let cal = calendar("America/New_York")
    let now = date(2026, 6, 15, 9, 0, in: cal)

    suite("Usage severity thresholds") {
        test("bands follow the documented used-percentage ranges") {
            expectEqual(UsageSeverity.forUsedPercent(0), .normal)
            expectEqual(UsageSeverity.forUsedPercent(59.9), .normal)
            expectEqual(UsageSeverity.forUsedPercent(60), .warning)
            expectEqual(UsageSeverity.forUsedPercent(79.9), .warning)
            expectEqual(UsageSeverity.forUsedPercent(80), .high)
            expectEqual(UsageSeverity.forUsedPercent(94.9), .high)
            expectEqual(UsageSeverity.forUsedPercent(95), .critical)
            expectEqual(UsageSeverity.forUsedPercent(100), .critical)
        }
    }

    suite("Metric values") {
        test("a count-based metric derives its own percentage and remainder") {
            let m = UsageMetric(id: "x", name: "Pro Messages", usedCount: 14, limitCount: 50)
            expectEqual(m.remainingCount, 36)
            expectEqual(m.effectiveUsedPercent.map { ($0 * 10).rounded() / 10 }, 28)
        }

        test("a percentage metric reports what remains without being asked twice") {
            let m = UsageMetric(id: "x", name: "Weekly", usedPercent: 88)
            expectEqual(m.remainingPercent, 12)
        }

        test("a metric with no data has no percentage to render") {
            let m = UsageMetric(id: "x", name: "Unknown", state: .unsupported)
            expectNil(m.effectiveUsedPercent)
            expect(!m.isRenderableValue)
        }

        test("the headline is the worst renderable metric, so a glance catches it") {
            let usage = AccountUsage(accountID: UUID(), metrics: [
                UsageMetric(id: "a", name: "Session", usedPercent: 12),
                UsageMetric(id: "b", name: "Weekly", usedPercent: 88),
                UsageMetric(id: "c", name: "Messages", state: .unsupported),
            ])
            expectEqual(usage.headlineMetric?.id, "b")
        }

        test("an account with nothing renderable has no headline") {
            let usage = AccountUsage(accountID: UUID(), metrics: [
                UsageMetric(id: "c", name: "Messages", state: .unsupported),
            ])
            expectNil(usage.headlineMetric)
        }
    }

    suite("Stale data") {
        test("fresh data stays available") {
            let metrics = [UsageMetric(id: "a", name: "Weekly", usedPercent: 40, state: .available)]
            let out = UsageCoordinator.applyStaleness(to: metrics, fetchedAt: now.addingTimeInterval(-60),
                                                      hasError: false, now: now)
            expectEqual(out[0].state, .available)
        }

        test("old data is marked stale but keeps its value") {
            let metrics = [UsageMetric(id: "a", name: "Weekly", usedPercent: 40, state: .available)]
            let out = UsageCoordinator.applyStaleness(to: metrics, fetchedAt: now.addingTimeInterval(-3600),
                                                      hasError: false, now: now)
            expectEqual(out[0].state, .stale)
            expectEqual(out[0].usedPercent, 40, "a failed refresh costs freshness, never the number")
        }

        test("a failed refresh marks data stale immediately") {
            let metrics = [UsageMetric(id: "a", name: "Weekly", usedPercent: 40, state: .available)]
            let out = UsageCoordinator.applyStaleness(to: metrics, fetchedAt: now,
                                                      hasError: true, now: now)
            expectEqual(out[0].state, .stale)
        }

        test("states that were never a live value are left alone") {
            let metrics = [UsageMetric(id: "a", name: "Messages", state: .unsupported)]
            let out = UsageCoordinator.applyStaleness(to: metrics, fetchedAt: now.addingTimeInterval(-9999),
                                                      hasError: true, now: now)
            expectEqual(out[0].state, .unsupported, "“unavailable” does not become “stale”")
        }
    }

    suite("Notifications") {
        func usage(_ accountID: UUID, percent: Double, reset: Date?) -> AccountUsage {
            AccountUsage(accountID: accountID, metrics: [
                UsageMetric(id: "claude.weekly_all", name: "Weekly (all)",
                            usedPercent: percent, resetsAt: reset, state: .available),
            ])
        }

        test("a warning fires once when the threshold is crossed") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.claude, name: "Personal Claude")
            let reset = date(2026, 6, 22, 2, 0, in: cal)

            let first = tracker.usageAlerts(for: account, usage: usage(account.id, percent: 92, reset: reset),
                                            settings: settings)
            expectEqual(first.count, 1)
            expect(first[0].title.contains("Personal Claude"))
            expect(first[0].body.contains("90") == false, "the body reports the real value, not the threshold")
            expect(first[0].body.contains("92%"))
        }

        test("and does not fire again inside the same window") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.claude)
            let reset = date(2026, 6, 22, 2, 0, in: cal)
            _ = tracker.usageAlerts(for: account, usage: usage(account.id, percent: 92, reset: reset), settings: settings)
            let second = tracker.usageAlerts(for: account, usage: usage(account.id, percent: 95, reset: reset), settings: settings)
            expectEqual(second.count, 0, "one alert per window, however often we poll")
        }

        test("a new window re-arms the warning automatically") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.claude)
            _ = tracker.usageAlerts(for: account,
                                    usage: usage(account.id, percent: 92, reset: date(2026, 6, 22, 2, 0, in: cal)),
                                    settings: settings)
            let next = tracker.usageAlerts(for: account,
                                           usage: usage(account.id, percent: 91, reset: date(2026, 6, 29, 2, 0, in: cal)),
                                           settings: settings)
            expectEqual(next.count, 1, "after the reset the warning is available again")
        }

        test("two accounts on the same provider do not suppress each other") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let a = makeAccount(.claude, name: "Personal Claude")
            let b = makeAccount(.claude, name: "Work Claude")
            let reset = date(2026, 6, 22, 2, 0, in: cal)
            let first = tracker.usageAlerts(for: a, usage: usage(a.id, percent: 92, reset: reset), settings: settings)
            let second = tracker.usageAlerts(for: b, usage: usage(b.id, percent: 92, reset: reset), settings: settings)
            expectEqual(first.count, 1)
            expectEqual(second.count, 1)
            expect(second[0].title.contains("Work Claude"))
        }

        test("dropping back below the threshold re-arms the warning") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.claude)
            let reset = date(2026, 6, 22, 2, 0, in: cal)
            _ = tracker.usageAlerts(for: account, usage: usage(account.id, percent: 92, reset: reset), settings: settings)
            _ = tracker.usageAlerts(for: account, usage: usage(account.id, percent: 40, reset: reset), settings: settings)
            let again = tracker.usageAlerts(for: account, usage: usage(account.id, percent: 93, reset: reset), settings: settings)
            expectEqual(again.count, 1)
        }

        test("below the threshold, nothing fires") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.claude)
            expectEqual(tracker.usageAlerts(for: account,
                                            usage: usage(account.id, percent: 89, reset: nil),
                                            settings: settings).count, 0)
        }

        test("an account's own threshold overrides the global one") {
            let settings = AppSettings(defaults: scratchDefaults())   // global 90
            let tracker = NotificationTracker()
            let account = makeAccount(.claude, threshold: 50)
            expectEqual(tracker.usageAlerts(for: account,
                                            usage: usage(account.id, percent: 60, reset: nil),
                                            settings: settings).count, 1)
        }

        test("warnings can be switched off entirely") {
            let settings = AppSettings(defaults: scratchDefaults())
            settings.usageWarningsEnabled = false
            let tracker = NotificationTracker()
            let account = makeAccount(.claude)
            expectEqual(tracker.usageAlerts(for: account,
                                            usage: usage(account.id, percent: 99, reset: nil),
                                            settings: settings).count, 0)
        }

        test("a count-based metric warns about what is left, not a percentage") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.openAI, name: "Business Premium")
            let u = AccountUsage(accountID: account.id, metrics: [
                UsageMetric(id: "openai.messages", name: "Messages",
                            usedCount: 45, limitCount: 50, state: .available),
            ])
            let alerts = tracker.usageAlerts(for: account, usage: u, settings: settings)
            expectEqual(alerts.count, 1)
            expect(alerts[0].body.contains("Only 5 left of 50"))
        }

        test("unsupported metrics never generate a warning") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.openAI)
            let u = AccountUsage(accountID: account.id, metrics: [
                UsageMetric(id: "openai.pro_messages", name: "ChatGPT messages", state: .unsupported),
            ])
            expectEqual(tracker.usageAlerts(for: account, usage: u, settings: settings).count, 0)
        }

        test("an auth warning fires once and re-arms only after recovery") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.claude, name: "Work Claude")
            let error = AccountError(kind: .expiredCredential, message: "Authentication expired.",
                                     recovery: "Open Claude Code to sign in again.")
            expectNotNil(tracker.authAlert(for: account, error: error, settings: settings))
            expectNil(tracker.authAlert(for: account, error: error, settings: settings), "not twice")
            expectNil(tracker.authAlert(for: account, error: nil, settings: settings))
            expectNotNil(tracker.authAlert(for: account, error: error, settings: settings),
                         "after recovering, a later failure warns again")
        }

        test("a network blip is not an auth warning") {
            let settings = AppSettings(defaults: scratchDefaults())
            let tracker = NotificationTracker()
            let account = makeAccount(.claude)
            let error = AccountError(kind: .network, message: "Network unavailable.")
            expectNil(tracker.authAlert(for: account, error: error, settings: settings))
        }

        test("notification state persists and can be reset") {
            let defaults = scratchDefaults()
            let settings = AppSettings(defaults: scratchDefaults())
            let account = makeAccount(.claude)
            let reset = date(2026, 6, 22, 2, 0, in: cal)
            let first = NotificationTracker(defaults: defaults)
            _ = first.usageAlerts(for: account, usage: usage(account.id, percent: 92, reset: reset), settings: settings)

            let reopened = NotificationTracker(defaults: defaults)
            expectEqual(reopened.usageAlerts(for: account, usage: usage(account.id, percent: 92, reset: reset),
                                             settings: settings).count, 0,
                        "a restart must not re-send an alert already shown")
            reopened.reset()
            expectEqual(reopened.usageAlerts(for: account, usage: usage(account.id, percent: 92, reset: reset),
                                             settings: settings).count, 1)
        }
    }

    suite("Error classification") {
        test("401 and 403 become an actionable reconnect message per provider") {
            let claude = HTTP.classify(HTTPError(status: 401, retryAfter: nil), provider: .claude)
            expectEqual(claude.kind, .authenticationFailed)
            expect(claude.recovery?.contains("Claude Code") == true)

            let openAI = HTTP.classify(HTTPError(status: 403, retryAfter: nil), provider: .openAI)
            expectEqual(openAI.kind, .authenticationFailed)
            expect(openAI.recovery?.contains("codex") == true)
        }

        test("429 is a rate limit and 5xx is provider unavailability") {
            expectEqual(HTTP.classify(HTTPError(status: 429, retryAfter: 30), provider: .claude).kind, .rateLimited)
            expectEqual(HTTP.classify(HTTPError(status: 503, retryAfter: nil), provider: .claude).kind, .providerUnavailable)
        }

        test("a bad body is a parsing error, not an auth problem") {
            expectEqual(HTTP.classify(TransportError.badJSON, provider: .openAI).kind, .parsing)
            expectEqual(HTTP.classify(TransportError.emptyUsage, provider: .openAI).kind, .parsing)
        }

        test("no error message ever carries credential material") {
            let errors = [
                HTTP.classify(HTTPError(status: 401, retryAfter: nil), provider: .claude),
                HTTP.classify(HTTPError(status: 500, retryAfter: nil), provider: .openAI),
                HTTP.classify(TransportError.badJSON, provider: .openAI),
            ]
            for e in errors {
                let text = e.message + (e.recovery ?? "")
                expect(!text.lowercased().contains("bearer"))
                expect(!text.lowercased().contains("token"))
            }
        }

        test("an error maps to the metric state the UI should render") {
            expectEqual(AccountError(kind: .expiredCredential, message: "").metricState, .authenticationRequired)
            expectEqual(AccountError(kind: .rateLimited, message: "").metricState, .rateLimited)
            expectEqual(AccountError(kind: .network, message: "").metricState, .error)
        }

        test("Retry-After is honoured in both of its forms") {
            expectEqual(HTTP.parseRetryAfter("120"), 120)
            expectNil(HTTP.parseRetryAfter(nil))
            expectNil(HTTP.parseRetryAfter("   "))
            expectNotNil(HTTP.parseRetryAfter("Wed, 21 Oct 2099 07:28:00 GMT"))
        }
    }

    suite("Diagnostics redaction") {
        test("JWTs, keys and bearer headers never survive redaction") {
            let text = """
                Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123signature
                "access_token": "sk-verysecretvaluehere123456"
                "refresh_token":"another-secret-value"
                """
            let out = Redact.secrets(text)
            expect(!out.contains("abc123signature"))
            expect(!out.contains("verysecretvaluehere"))
            expect(!out.contains("another-secret-value"))
        }

        test("home paths are replaced so a diagnostic dump is safe to paste") {
            let out = Redact.homePaths("\(NSHomeDirectory())/.codex/auth.json")
            expect(out.hasPrefix("~"), "got \(out)")
            expect(!out.contains(NSUserName()))
        }

        test("e-mail addresses are masked by default") {
            expectEqual(Redact.email("user@example.com"), "u***@example.com")
        }

        test("a full diagnostics report contains no secrets and no raw home path") {
            let settings = AppSettings(defaults: scratchDefaults())
            let account = makeAccount(.openAI, name: "Business Premium")
            let state = AccountRuntimeState(
                usage: AccountUsage(accountID: account.id,
                                    metrics: [UsageMetric(id: "openai.primary", name: "Codex Weekly",
                                                          usedPercent: 89, state: .available)],
                                    accountLabel: "user@example.com · plan: Plus"),
                error: nil, isRefreshing: false, lastSuccess: now)
            let report = DiagnosticsReport.build(accounts: [account],
                                                 states: [account.id: state],
                                                 credentialStatus: [account.id: .detected],
                                                 settings: settings,
                                                 includeIdentities: false,
                                                 now: now)
            expect(report.contains("Business Premium"))
            expect(report.contains("Codex Weekly"))
            expect(report.contains("u***@example.com"), "identity masked unless opted in")
            expect(!report.contains("user@example.com"))
            expect(!report.contains(NSHomeDirectory()))
        }
    }
}
