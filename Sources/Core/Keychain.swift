// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Venture Studios. See NOTICE.

import Foundation

/// Run a helper process and capture its output.
@discardableResult
func runProcess(_ launchPath: String, _ args: [String], stdin: String? = nil) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe(); let err = Pipe()
    p.standardOutput = out; p.standardError = err
    if let stdin = stdin {
        let inPipe = Pipe()
        p.standardInput = inPipe
        try? p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()
    } else {
        try? p.run()
    }
    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, o, e)
}

/// Generic-password access through `/usr/bin/security`.
///
/// The app is distributed unsigned and built locally with `swiftc`, so it has no
/// stable code-signing identity for a Security.framework ACL to bind to. The
/// `security` tool is already the mechanism the upstream project used to read
/// Claude Code's item, and it keeps the app's own items readable across
/// rebuilds. See docs/DECISIONS.md.
enum Keychain {

    /// Read a password. Returns nil when the item does not exist or access was
    /// denied — the caller reports "missing", never the underlying text, which
    /// could contain the secret on some error paths.
    static func read(service: String, account: String) -> String? {
        let r = runProcess("/usr/bin/security",
                           ["find-generic-password", "-s", service, "-a", account, "-w"])
        guard r.status == 0 else { return nil }
        let value = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Create or update an item. `-U` updates in place so we never end up with
    /// duplicate items for the same account.
    @discardableResult
    static func write(service: String, account: String, value: String, label: String? = nil) -> Bool {
        let r = runProcess("/usr/bin/security",
                           ["add-generic-password", "-U",
                            "-s", service, "-a", account,
                            "-l", label ?? service, "-w", value])
        if r.status != 0 {
            Diagnostics.shared.error("keychain write failed for service \(service) (status \(r.status))")
        }
        return r.status == 0
    }

    /// Delete an item. Only ever called with this app's own service name.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let r = runProcess("/usr/bin/security",
                           ["delete-generic-password", "-s", service, "-a", account])
        return r.status == 0
    }

    static func exists(service: String, account: String) -> Bool {
        runProcess("/usr/bin/security",
                   ["find-generic-password", "-s", service, "-a", account]).status == 0
    }
}
