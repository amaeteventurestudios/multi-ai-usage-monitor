import Foundation

/// Identity of the application, in one place so branding can never drift between
/// the bundle, the menu, the About pane and the build script.
enum AppInfo {
    static let name = "Multi AI Usage Monitor"
    /// Short heading used at the top of the menu bar dropdown.
    static let menuHeading = "AI Usage"
    static let bundleIdentifier = "com.amaeteventurestudios.multi-ai-usage-monitor"
    /// Bundle identifier of the upstream-derived build this project grew out of.
    /// Used only to migrate a previous installation's preferences.
    static let legacyBundleIdentifier = "com.local.claudeusage"
    static let version = "0.1.0"

    static let repositoryURL = "https://github.com/amaeteventurestudios/multi-ai-usage-monitor"
    static let upstreamURL = "https://github.com/stavrop/ai-usage-monitor"
    static let licenseName = "Apache License 2.0"

    /// Keychain service that holds credentials this app imported for itself.
    /// Deliberately distinct from any provider's own service name so removing an
    /// account here can never delete Claude Code's or Codex's credential.
    static let appKeychainService = bundleIdentifier + ".credentials"

    static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
