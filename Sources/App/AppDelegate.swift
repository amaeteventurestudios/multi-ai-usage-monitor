import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let settings = AppSettings()
    lazy var store = AccountStore()
    lazy var notifications = NotificationTracker(defaults: .standard)
    lazy var coordinator = UsageCoordinator(store: store, settings: settings,
                                            notifications: notifications)

    private var statusItem: NSStatusItem!
    private lazy var settingsWC: SettingsWindowController = {
        let wc = SettingsWindowController(coordinator: coordinator)
        wc.onChange = { [weak self] in self?.applySettings() }
        return wc
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.shared.minimumLevel = settings.debugLogging ? .debug : .info
        Diagnostics.shared.info("\(AppInfo.name) \(AppInfo.version) starting on macOS \(AppInfo.osVersionString) (\(AppInfo.architecture))")

        migrateIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = AppInfo.menuHeading + " …"
        statusItem.menu = NSMenu()

        coordinator.onChange = { [weak self] in
            self?.renderTitle()
            self?.rebuildMenu()
        }
        coordinator.start()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        Diagnostics.shared.flushToDisk()
    }

    // MARK: - First launch

    /// Bring a previous installation forward, or bootstrap from whatever
    /// credentials this Mac already has. Runs once; after that the account list
    /// is the source of truth and is never silently rewritten.
    private func migrateIfNeeded() {
        guard !settings.legacyMigrationDone else { return }
        defer {
            settings.legacyMigrationDone = true
            settings.schemaVersion = AppSettings.currentSchemaVersion
        }
        guard store.accounts.isEmpty else { return }

        let legacyDefaults = UserDefaults(suiteName: AppInfo.legacyBundleIdentifier)
        let legacy = LegacySettingsSnapshot.read(from: legacyDefaults)
        if legacy != nil { Diagnostics.shared.info("found settings from a previous installation") }
        LegacyMigration.apply(legacy: legacy, to: settings)

        // Names are not decided here. The coordinator asks each provider who
        // the credential belongs to on first launch, so a carried-over account
        // ends up named after its account rather than after a counter.
        let detected = DetectedCredentials(
            claudeCodeKeychain: ClaudeCredentialStore.read(source: .claudeCodeKeychain) != nil,
            codexDefault: CodexCredentialStore.read(source: .codexDefault) != nil)

        let accounts = LegacyMigration.accounts(legacy: legacy, detected: detected)
        if !accounts.isEmpty {
            store.replaceAll(accounts)
            Diagnostics.shared.info("created \(accounts.count) account(s) from detected credentials")
        }
    }

    // MARK: - Settings changes

    func applySettings() {
        coordinator.refreshCredentialStatuses()
        coordinator.restartTimers()
        renderTitle()
        rebuildMenu()
    }

    // MARK: - Menu bar title

    private func renderTitle() {
        let title = coordinator.menuBarTitle() ?? (AppInfo.menuHeading + " …")
        DispatchQueue.main.async { self.statusItem.button?.title = title }
    }

    // MARK: - Dropdown

    private func rebuildMenu() {
        DispatchQueue.main.async { self.buildMenuNow() }
    }

    private func buildMenuNow() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = UsageRowView.rowWidth

        func disabled(_ title: String, font: NSFont? = nil, color: NSColor? = nil) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if font != nil || color != nil {
                var attrs: [NSAttributedString.Key: Any] = [:]
                if let f = font { attrs[.font] = f }
                if let c = color { attrs[.foregroundColor] = c }
                item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
            }
            menu.addItem(item)
        }

        func customView(_ view: NSView) {
            let item = NSMenuItem()
            item.isEnabled = false
            item.view = view
            menu.addItem(item)
        }

        disabled(AppInfo.menuHeading,
                 font: NSFont.systemFont(ofSize: 11, weight: .bold),
                 color: .secondaryLabelColor)

        let accounts = store.accounts.filter { $0.enabled }
        if accounts.isEmpty {
            menu.addItem(.separator())
            disabled("No accounts configured")
            disabled("Add one in Settings…", font: NSFont.systemFont(ofSize: 11),
                     color: .secondaryLabelColor)
        }

        var lastProvider: ProviderKind?
        for account in accounts {
            if account.provider != lastProvider {
                menu.addItem(.separator())
                disabled(account.provider.displayName.uppercased(),
                         font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         color: .tertiaryLabelColor)
                lastProvider = account.provider
            }

            let state = coordinator.state(for: account)
            let status = coordinator.credentialStatus[account.id] ?? .missing
            // Badge, then whatever secondary metadata we actually know (plan,
            // organisation), then the credential's health. The account's own
            // name carries the identity, so it never needs repeating here.
            var parts = [account.shortDisplayName]
            if let subtitle = account.subtitle { parts.append(subtitle) }
            parts.append(status == .detected ? "Live" : "Reconnect required")
            customView(AccountHeaderView(name: account.displayName,
                                         subtitle: parts.joined(separator: " · "),
                                         accent: accent(for: account.provider)))

            if let error = state.error {
                // Account-local, and shown next to whatever numbers we still
                // have rather than replacing them.
                disabled("⚠︎ " + error.message,
                         font: NSFont.systemFont(ofSize: 11, weight: .medium),
                         color: .systemOrange)
                if let recovery = error.recovery {
                    disabled(recovery, font: NSFont.systemFont(ofSize: 11),
                             color: .secondaryLabelColor)
                }
            }

            let metrics = coordinator.displayMetrics(for: account)
            if metrics.isEmpty && state.error == nil {
                disabled(state.isRefreshing ? "Loading…" : "No usage data yet",
                         font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
            }
            for metric in metrics {
                customView(UsageRowView(metric: metric, showCountdown: settings.showResetCountdown))
            }
            for note in state.usage?.notes ?? [] {
                disabled(note, font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
            }
        }

        menu.addItem(.separator())
        disabled(Fmt.updatedLine(coordinator.lastUpdated),
                 font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(manualRefresh),
                                     keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About \(AppInfo.name)…", action: #selector(openAbout),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func accent(for provider: ProviderKind) -> NSColor {
        switch provider {
        case .claude: return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.29, alpha: 1)
        case .openAI: return NSColor(srgbRed: 0.10, green: 0.65, blue: 0.53, alpha: 1)
        }
    }

    // MARK: - Actions

    @objc private func manualRefresh() { coordinator.refreshAll() }

    @objc private func openSettings() { settingsWC.show() }

    @objc private func openAbout() { settingsWC.show(tab: .about) }
}
