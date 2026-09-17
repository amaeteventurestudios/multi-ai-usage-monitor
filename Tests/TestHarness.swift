import Foundation

/// A tiny assertion harness.
///
/// XCTest ships with Xcode, not with the Command Line Tools, and this project
/// builds with `swiftc` alone precisely so that a contributor with only the CLT
/// can work on it. Depending on XCTest would mean the test suite could not run
/// on the same machines the app is built on. See docs/DECISIONS.md.
final class TestRunner {
    static let shared = TestRunner()

    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentTest = ""

    func run(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        do {
            try body()
            print("  ✓ \(name)")
        } catch {
            failures.append("\(name): threw \(error)")
            print("  ✗ \(name): threw \(error)")
        }
    }

    func group(_ name: String, _ body: () -> Void) {
        print("\n\(name)")
        body()
    }

    func record(_ ok: Bool, _ message: @autoclosure () -> String, file: String, line: Int) {
        if ok { passed += 1; return }
        let short = (file as NSString).lastPathComponent
        let text = "\(currentTest) — \(message()) (\(short):\(line))"
        failures.append(text)
        print("    ✗ \(text)")
    }

    func summary() -> Int32 {
        print("\n────────────────────────────────────────")
        if failures.isEmpty {
            print("All \(passed) assertions passed.")
            return 0
        }
        print("\(failures.count) failure(s), \(passed) assertion(s) passed:")
        for f in failures { print("  • \(f)") }
        return 1
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
            file: String = #file, line: Int = #line) {
    TestRunner.shared.record(condition, message(), file: file, line: line)
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "",
                               file: String = #file, line: Int = #line) {
    let note = message().isEmpty ? "" : " — \(message())"
    TestRunner.shared.record(a == b, "expected \(b), got \(a)\(note)", file: file, line: line)
}

func expectNil<T>(_ value: T?, _ message: @autoclosure () -> String = "expected nil",
                  file: String = #file, line: Int = #line) {
    TestRunner.shared.record(value == nil, "\(message()), got \(String(describing: value))",
                             file: file, line: line)
}

func expectNotNil<T>(_ value: T?, _ message: @autoclosure () -> String = "expected a value",
                     file: String = #file, line: Int = #line) {
    TestRunner.shared.record(value != nil, message(), file: file, line: line)
}

func test(_ name: String, _ body: () throws -> Void) {
    TestRunner.shared.run(name, body)
}

func suite(_ name: String, _ body: () -> Void) {
    TestRunner.shared.group(name, body)
}

// MARK: - Shared helpers

/// A scratch defaults domain per test, so nothing touches the real app's
/// preferences and tests cannot leak into each other.
func scratchDefaults() -> UserDefaults {
    let name = "multi-ai-usage-monitor.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// A fixed calendar so date tests do not depend on the machine's locale.
func calendar(_ timeZoneID: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: timeZoneID)!
    cal.locale = Locale(identifier: "en_US_POSIX")
    return cal
}

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, in cal: Calendar) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
    return cal.date(from: c)!
}

func components(_ date: Date, in cal: Calendar) -> DateComponents {
    cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
}

/// Fixtures live beside the tests. The path is overridable so the suite can be
/// run from anywhere.
func fixture(_ name: String) -> [String: Any] {
    let dir = ProcessInfo.processInfo.environment["FIXTURES_DIR"] ?? "Tests/Fixtures"
    let path = (dir as NSString).appendingPathComponent(name)
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fatalError("fixture \(name) not found at \(path)")
    }
    return obj
}

func makeAccount(_ provider: ProviderKind = .claude,
                 name: String? = nil,
                 email: String? = nil,
                 weekly: WeeklyResetRule? = nil,
                 preferProvider: Bool = true,
                 threshold: Int? = nil) -> AIAccount {
    AIAccount(provider: provider,
              customDisplayName: name,
              identity: email.map { makeIdentity(email: $0) },
              credentialSource: provider == .claude ? .claudeCodeKeychain : .codexDefault,
              resetOverrides: ResetOverrides(preferProviderReset: preferProvider, weekly: weekly),
              notificationThresholdPercent: threshold)
}

func makeIdentity(email: String? = nil,
                  accountID: String? = nil,
                  plan: String? = nil,
                  verified: Bool = true) -> AccountIdentity {
    AccountIdentity(email: email, providerAccountID: accountID, planLabel: plan, verified: verified)
}
