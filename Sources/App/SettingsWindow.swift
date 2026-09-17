import AppKit

/// The settings window.
///
/// Organised by what the user is trying to change rather than by which provider
/// the code happens to talk to: accounts first, then how much the menu bar
/// says, then warnings, refresh, and the escape hatches.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    enum Tab: Int, CaseIterable {
        case accounts, display, notifications, refresh, advanced, about
        var title: String {
            switch self {
            case .accounts: return "Accounts"
            case .display: return "Display"
            case .notifications: return "Notifications"
            case .refresh: return "Refresh"
            case .advanced: return "Advanced"
            case .about: return "About"
            }
        }
    }

    var onChange: (() -> Void)?

    private let coordinator: UsageCoordinator
    private var settings: AppSettings { coordinator.settings }
    private var store: AccountStore { coordinator.store }

    private var tabView: NSTabView!
    private var accountsStack: NSStackView!
    private var lastRefreshLabel: NSTextField!
    private var editor: AccountEditorController?

    init(coordinator: UsageCoordinator) {
        self.coordinator = coordinator
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "\(AppInfo.name) Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.contentView = buildBody()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show(tab: Tab = .accounts) {
        reloadAccounts()
        refreshLastRefreshLabel()
        tabView.selectTabViewItem(at: tab.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Shared builders

    private func label(_ text: String, size: CGFloat = NSFont.systemFontSize,
                       color: NSColor = .labelColor, bold: Bool = false,
                       wrapWidth: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        l.textColor = color
        if let w = wrapWidth {
            l.lineBreakMode = .byWordWrapping
            l.usesSingleLineMode = false
            l.preferredMaxLayoutWidth = w
        } else {
            l.lineBreakMode = .byTruncatingMiddle
        }
        return l
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        return s
    }

    private func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    private func smallButton(_ title: String, _ action: Selector, tag: Int = 0) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 11)
        b.tag = tag
        return b
    }

    private func buildBody() -> NSView {
        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        for tab in Tab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = view(for: tab)
            tabView.addTabViewItem(item)
        }
        let container = NSView()
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func view(for tab: Tab) -> NSView {
        switch tab {
        case .accounts: return accountsView()
        case .display: return displayView()
        case .notifications: return notificationsView()
        case .refresh: return refreshView()
        case .advanced: return advancedView()
        case .about: return aboutView()
        }
    }

    // MARK: - Accounts tab

    private func accountsView() -> NSView {
        accountsStack = NSStackView()
        accountsStack.orientation = .vertical
        accountsStack.alignment = .leading
        accountsStack.spacing = 12
        accountsStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        accountsStack.translatesAutoresizingMaskIntoConstraints = false

        let clip = NSView()
        clip.addSubview(accountsStack)
        NSLayoutConstraint.activate([
            accountsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            accountsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            accountsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            accountsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = clip
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -16).isActive = true

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        reloadAccounts()
        return container
    }

    /// Rebuilt wholesale on every change. The list is a handful of rows, so the
    /// simplicity is worth far more than the redraw.
    func reloadAccounts() {
        guard accountsStack != nil else { return }
        coordinator.refreshCredentialStatuses()
        accountsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for provider in ProviderKind.allCases {
            accountsStack.addArrangedSubview(
                label("\(provider.displayName) Accounts", size: 13, bold: true))

            let accounts = store.accounts(for: provider)
            if accounts.isEmpty {
                accountsStack.addArrangedSubview(
                    label("No \(provider.displayName) accounts yet.", size: 11,
                          color: .secondaryLabelColor))
            }
            for account in accounts {
                accountsStack.addArrangedSubview(accountCard(account))
            }

            let add = smallButton("+ Add \(provider.displayName) Account",
                                  #selector(addAccountTapped(_:)),
                                  tag: ProviderKind.allCases.firstIndex(of: provider) ?? 0)
            accountsStack.addArrangedSubview(add)

            let sep = NSBox(); sep.boxType = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            accountsStack.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalTo: accountsStack.widthAnchor, constant: -32).isActive = true
        }

        accountsStack.addArrangedSubview(
            label("This app never signs you in. It reads credentials the provider's own "
                + "tools already store on this Mac, or a copy you explicitly imported into "
                + "the macOS Keychain. It never writes ~/.codex/auth.json.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480))
    }

    private func accountCard(_ account: AIAccount) -> NSView {
        let index = store.accounts.firstIndex(where: { $0.id == account.id }) ?? 0
        let status = coordinator.credentialStatus[account.id] ?? .missing
        let state = coordinator.state(for: account)

        let enabledBox = NSButton(checkboxWithTitle: account.displayName,
                                  target: self, action: #selector(toggleAccount(_:)))
        enabledBox.state = account.enabled ? .on : .off
        enabledBox.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        enabledBox.tag = index

        let statusDot = label(statusText(status), size: 11, color: statusColor(status))

        let credential = label("Credential: \(account.credentialSource.kindLabel) · "
                             + "\(account.credentialSource.locationLabel)",
                               size: 11, color: .secondaryLabelColor, wrapWidth: 440)

        let resetText: String
        if let w = account.resetOverrides.weekly {
            resetText = account.resetOverrides.preferProviderReset
                ? "Reset: provider time, falling back to \(w.weekdayName) \(String(format: "%02d:%02d", w.hour, w.minute))"
                : "Reset: \(w.weekdayName) \(String(format: "%02d:%02d", w.hour, w.minute)) (local schedule)"
        } else {
            resetText = "Reset: whatever the provider reports"
        }
        let reset = label(resetText, size: 11, color: .secondaryLabelColor, wrapWidth: 440)

        var lines: [NSView] = [hstack([enabledBox, statusDot]), credential, reset]

        if let error = state.error {
            lines.append(label("⚠︎ \(error.message)", size: 11, color: .systemOrange, wrapWidth: 440))
        }
        if let usageLabel = state.usage?.accountLabel {
            lines.append(label(usageLabel, size: 11, color: .tertiaryLabelColor, wrapWidth: 440))
        }

        let buttons = hstack([
            smallButton("Edit", #selector(editAccountTapped(_:)), tag: index),
            smallButton("Change Credential", #selector(changeCredentialTapped(_:)), tag: index),
            smallButton("Reconnect", #selector(reconnectTapped(_:)), tag: index),
            smallButton("↑", #selector(moveUpTapped(_:)), tag: index),
            smallButton("↓", #selector(moveDownTapped(_:)), tag: index),
            smallButton("Remove", #selector(removeAccountTapped(_:)), tag: index),
        ], spacing: 6)
        lines.append(buttons)

        let box = NSStackView(views: lines)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        return box
    }

    private func statusText(_ s: CredentialStatus) -> String {
        switch s {
        case .detected: return "● Connected"
        case .missing: return "○ Missing"
        case .expired: return "◐ Expired"
        case .invalid: return "○ Invalid"
        case .unreadable: return "○ Unreadable"
        }
    }

    private func statusColor(_ s: CredentialStatus) -> NSColor {
        switch s {
        case .detected: return .systemGreen
        case .expired: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private func account(atTag tag: Int) -> AIAccount? {
        guard tag >= 0, tag < store.accounts.count else { return nil }
        return store.accounts[tag]
    }

    // MARK: - Account actions

    @objc private func addAccountTapped(_ sender: NSButton) {
        let provider = ProviderKind.allCases[min(max(0, sender.tag), ProviderKind.allCases.count - 1)]
        let existing = store.accounts(for: provider).count
        let defaultSource: CredentialSource = provider == .claude
            ? (store.accounts(for: .claude).contains { $0.credentialSource == .claudeCodeKeychain }
                ? .appKeychain(id: UUID().uuidString) : .claudeCodeKeychain)
            : (store.accounts(for: .openAI).contains { $0.credentialSource == .codexDefault }
                ? .file(path: "") : .codexDefault)

        var account = AIAccount(provider: provider,
                                displayName: "\(provider.displayName) Account \(existing + 1)",
                                credentialSource: defaultSource)
        // A credential that identifies itself names the account better than a
        // counter does — but only when there really is one to read.
        if let suggested = ProviderRegistry.provider(for: provider)
            .suggestedDisplayName(for: defaultSource), existing == 0 {
            account.displayName = suggested
        }
        presentEditor(for: account, isNew: true)
    }

    @objc private func editAccountTapped(_ sender: NSButton) {
        guard let a = account(atTag: sender.tag) else { return }
        presentEditor(for: a, isNew: false)
    }

    private func presentEditor(for account: AIAccount, isNew: Bool) {
        guard let window = window else { return }
        let editor = AccountEditorController(account: account, isNew: isNew,
                                             coordinator: coordinator)
        editor.onSave = { [weak self] updated in
            guard let self = self else { return }
            if isNew { self.coordinator.addAccount(updated) }
            else { self.coordinator.updateAccount(updated) }
            self.reloadAccounts()
            self.onChange?()
        }
        editor.onDelete = { [weak self] id in
            self?.coordinator.removeAccount(id: id)
            self?.reloadAccounts()
            self?.onChange?()
        }
        self.editor = editor
        editor.beginSheet(on: window)
    }

    @objc private func toggleAccount(_ sender: NSButton) {
        guard let a = account(atTag: sender.tag) else { return }
        var updated = a
        updated.enabled = sender.state == .on
        coordinator.updateAccount(updated)
        reloadAccounts()
        onChange?()
    }

    @objc private func changeCredentialTapped(_ sender: NSButton) {
        guard let a = account(atTag: sender.tag) else { return }
        presentEditor(for: a, isNew: false)
    }

    @objc private func reconnectTapped(_ sender: NSButton) {
        guard let a = account(atTag: sender.tag) else { return }
        coordinator.refreshCredentialStatuses()
        coordinator.refresh(accountID: a.id)
        reloadAccounts()
    }

    @objc private func moveUpTapped(_ sender: NSButton) {
        guard let a = account(atTag: sender.tag) else { return }
        coordinator.moveAccount(id: a.id, by: -1)
        reloadAccounts(); onChange?()
    }

    @objc private func moveDownTapped(_ sender: NSButton) {
        guard let a = account(atTag: sender.tag) else { return }
        coordinator.moveAccount(id: a.id, by: 1)
        reloadAccounts(); onChange?()
    }

    @objc private func removeAccountTapped(_ sender: NSButton) {
        guard let a = account(atTag: sender.tag), let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(a.displayName)”?"
        alert.informativeText = "This removes the account from \(AppInfo.name). "
            + "Any credential copy this app imported is deleted; credentials owned by "
            + "Claude Code or the ChatGPT app are left untouched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.coordinator.removeAccount(id: a.id)
            self?.reloadAccounts()
            self?.onChange?()
        }
    }

    // MARK: - Display tab

    private func displayView() -> NSView {
        let popup = NSPopUpButton()
        for mode in MenuBarSummaryMode.allCases { popup.addItem(withTitle: mode.displayName) }
        popup.selectItem(at: MenuBarSummaryMode.allCases.firstIndex(of: settings.menuBarSummaryMode) ?? 0)
        popup.target = self
        popup.action = #selector(summaryModeChanged(_:))

        func check(_ title: String, _ value: Bool, _ action: Selector) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: self, action: action)
            b.state = value ? .on : .off
            return b
        }

        return vstack([
            label("Menu Bar Summary", size: 13, bold: true),
            popup,
            label("Compact shows every enabled account (C1, C2, G1…). Provider shows the "
                + "worst account per provider. Minimal shows just “AI”.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
            check("Show percentages", settings.showPercentages, #selector(toggleShowPercentages(_:))),
            check("Show short account badges instead of provider names",
                  settings.showProviderBadges, #selector(toggleShowBadges(_:))),
            check("Show reset countdown in the dropdown",
                  settings.showResetCountdown, #selector(toggleShowCountdown(_:))),
            check("Menu bar shows only the highest usage",
                  settings.onlyHighestInMenuBar, #selector(toggleOnlyHighest(_:))),
            label("Every percentage in this app is usage *used*, never remaining.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
        ])
    }

    @objc private func summaryModeChanged(_ sender: NSPopUpButton) {
        let idx = min(max(0, sender.indexOfSelectedItem), MenuBarSummaryMode.allCases.count - 1)
        settings.menuBarSummaryMode = MenuBarSummaryMode.allCases[idx]
        onChange?()
    }
    @objc private func toggleShowPercentages(_ s: NSButton) { settings.showPercentages = s.state == .on; onChange?() }
    @objc private func toggleShowBadges(_ s: NSButton) { settings.showProviderBadges = s.state == .on; onChange?() }
    @objc private func toggleShowCountdown(_ s: NSButton) { settings.showResetCountdown = s.state == .on; onChange?() }
    @objc private func toggleOnlyHighest(_ s: NSButton) { settings.onlyHighestInMenuBar = s.state == .on; onChange?() }

    // MARK: - Notifications tab

    private var thresholdField: NSTextField!

    private func notificationsView() -> NSView {
        let usage = NSButton(checkboxWithTitle: "Warn me when an account gets close to its limit",
                             target: self, action: #selector(toggleUsageWarnings(_:)))
        usage.state = settings.usageWarningsEnabled ? .on : .off

        thresholdField = NSTextField(string: "\(settings.warningThresholdPercent)")
        thresholdField.alignment = .right
        thresholdField.target = self
        thresholdField.action = #selector(commitThreshold)
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 54).isActive = true

        let auth = NSButton(checkboxWithTitle: "Warn me when an account needs to be reconnected",
                            target: self, action: #selector(toggleAuthWarnings(_:)))
        auth.state = settings.authWarningsEnabled ? .on : .off

        return vstack([
            label("Notifications", size: 13, bold: true),
            usage,
            hstack([label("Warning threshold"), thresholdField, label("% used")]),
            auth,
            label("Each warning fires once per usage window and re-arms itself after that "
                + "window resets, so a busy week does not turn into a stream of alerts. "
                + "Accounts can override the threshold individually in their editor.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
        ])
    }

    @objc private func toggleUsageWarnings(_ s: NSButton) { settings.usageWarningsEnabled = s.state == .on }
    @objc private func toggleAuthWarnings(_ s: NSButton) { settings.authWarningsEnabled = s.state == .on }
    @objc private func commitThreshold() {
        if let v = Int(thresholdField.stringValue) { settings.warningThresholdPercent = v }
        thresholdField.stringValue = "\(settings.warningThresholdPercent)"
    }

    // MARK: - Refresh tab

    private static let intervalChoices: [Int?] = [1, 5, 10, 15, 30, nil]

    private func refreshView() -> NSView {
        let popup = NSPopUpButton()
        for choice in SettingsWindowController.intervalChoices {
            popup.addItem(withTitle: choice.map { "Every \($0) minute\($0 == 1 ? "" : "s")" } ?? "Manual only")
        }
        let current = settings.refreshIntervalMinutes
        popup.selectItem(at: SettingsWindowController.intervalChoices.firstIndex { $0 == current } ?? 1)
        popup.target = self
        popup.action = #selector(intervalChanged(_:))

        lastRefreshLabel = label("", size: 11, color: .secondaryLabelColor)
        refreshLastRefreshLabel()

        let now = NSButton(title: "Refresh Now", target: self, action: #selector(refreshNowTapped))
        now.bezelStyle = .rounded

        return vstack([
            label("Automatic Refresh", size: 13, bold: true),
            popup,
            label("Usage windows are hours to days long, so polling harder buys nothing and "
                + "risks being rate-limited. Five minutes is the default.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
            lastRefreshLabel,
            now,
        ])
    }

    private func refreshLastRefreshLabel() {
        lastRefreshLabel?.stringValue = "Last successful refresh: "
            + (coordinator.lastUpdated.map { Fmt.updatedLine($0).replacingOccurrences(of: "Updated ", with: "") }
               ?? "never")
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let idx = min(max(0, sender.indexOfSelectedItem), SettingsWindowController.intervalChoices.count - 1)
        settings.refreshIntervalMinutes = SettingsWindowController.intervalChoices[idx]
        onChange?()
    }

    @objc private func refreshNowTapped() {
        coordinator.refreshAll()
        refreshLastRefreshLabel()
    }

    // MARK: - Advanced tab

    private func advancedView() -> NSView {
        let debug = NSButton(checkboxWithTitle: "Verbose local logging",
                             target: self, action: #selector(toggleDebug(_:)))
        debug.state = settings.debugLogging ? .on : .off

        let identities = NSButton(checkboxWithTitle: "Include e-mail addresses in diagnostics",
                                  target: self, action: #selector(toggleIdentities(_:)))
        identities.state = settings.diagnosticsIncludeIdentities ? .on : .off

        return vstack([
            label("Advanced", size: 13, bold: true),
            debug,
            identities,
            label("Diagnostics never contain tokens, cookies or authorization headers. "
                + "E-mail addresses are masked unless you turn that on.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
            hstack([
                NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics)),
                NSButton(title: "Open Logs", target: self, action: #selector(openLogs)),
            ]),
            hstack([
                NSButton(title: "Reset Notification State", target: self, action: #selector(resetNotifications)),
                NSButton(title: "Reset Local Settings", target: self, action: #selector(resetSettings)),
            ]),
            label("Resetting local settings restores display, refresh and notification "
                + "preferences. Your accounts and their credentials are left alone.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
        ])
    }

    @objc private func toggleDebug(_ s: NSButton) { settings.debugLogging = s.state == .on }
    @objc private func toggleIdentities(_ s: NSButton) { settings.diagnosticsIncludeIdentities = s.state == .on }

    @objc private func copyDiagnostics() {
        let report = DiagnosticsReport.build(accounts: store.accounts,
                                             states: coordinator.states,
                                             credentialStatus: coordinator.credentialStatus,
                                             settings: settings,
                                             includeIdentities: settings.diagnosticsIncludeIdentities)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func openLogs() {
        if let url = Diagnostics.shared.flushToDisk() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func resetNotifications() {
        coordinator.notifications.reset()
    }

    @objc private func resetSettings() {
        settings.resetToDefaults()
        onChange?()
        window?.contentView = buildBody()
        show(tab: .advanced)
    }

    // MARK: - About tab

    private func aboutView() -> NSView {
        let repo = NSButton(title: "★  Star on GitHub", target: self, action: #selector(openRepo))
        repo.bezelStyle = .rounded
        let upstream = NSButton(title: "Upstream project", target: self, action: #selector(openUpstream))
        upstream.bezelStyle = .rounded

        return vstack([
            label(AppInfo.name, size: 16, bold: true),
            label("Version \(AppInfo.version) · macOS \(AppInfo.osVersionString) · \(AppInfo.architecture)",
                  size: 11, color: .secondaryLabelColor),
            label("One menu bar dashboard for usage across multiple Claude and OpenAI accounts.",
                  size: 12, wrapWidth: 480),
            hstack([repo, upstream]),
            label("Open source under the \(AppInfo.licenseName).", size: 11,
                  color: .secondaryLabelColor, wrapWidth: 480),
            label("Derived from stavrop/ai-usage-monitor, © Georgios Stavropoulos, "
                + "used under the Apache License 2.0. Modifications © 2026 Amaete Umanah.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
            label("Privacy", size: 13, bold: true),
            label("Local-first. Credentials stay in the macOS Keychain or in the credential "
                + "files the provider's own tools already keep on this Mac. Usage is fetched "
                + "directly from Anthropic and OpenAI. There is no backend of our own, no "
                + "account, and no analytics or telemetry of any kind.",
                  size: 11, color: .secondaryLabelColor, wrapWidth: 480),
            label("Not affiliated with, endorsed by, or sponsored by Anthropic or OpenAI.",
                  size: 11, color: .tertiaryLabelColor, wrapWidth: 480),
        ])
    }

    @objc private func openRepo() {
        if let u = URL(string: AppInfo.repositoryURL) { NSWorkspace.shared.open(u) }
    }
    @objc private func openUpstream() {
        if let u = URL(string: AppInfo.upstreamURL) { NSWorkspace.shared.open(u) }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        commitThreshold()
        onChange?()
    }
}
