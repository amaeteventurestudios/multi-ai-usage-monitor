import AppKit

/// Editor for one account, presented as a sheet.
///
/// Everything that distinguishes one account from another lives here: its name,
/// whether it is on, which credential it reads, when its windows reset, and
/// whether it warns at a different level from everything else.
final class AccountEditorController: NSObject {

    var onSave: ((AIAccount) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private var account: AIAccount
    private let isNew: Bool
    private let coordinator: UsageCoordinator

    private var sheet: NSWindow!
    private var nameField: NSTextField!
    private var enabledBox: NSButton!
    private var sourcePopup: NSPopUpButton!
    private var sourceDetail: NSTextField!
    private var statusLabel: NSTextField!
    private var preferProviderBox: NSButton!
    private var useWeeklyBox: NSButton!
    private var weekdayPopup: NSPopUpButton!
    private var hourField: NSTextField!
    private var minuteField: NSTextField!
    private var customThresholdBox: NSButton!
    private var thresholdField: NSTextField!

    /// The credential file or imported blob chosen in this sheet but not yet saved.
    private var pendingFilePath: String?
    private var pendingImportedJSON: String?

    init(account: AIAccount, isNew: Bool, coordinator: UsageCoordinator) {
        self.account = account
        self.isNew = isNew
        self.coordinator = coordinator
        super.init()
    }

    // MARK: - Presentation

    func beginSheet(on parent: NSWindow) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
                         styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = isNew ? "Add Account" : "Edit Account"
        sheet.contentView = buildBody()
        parent.beginSheet(sheet, completionHandler: nil)
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    // MARK: - Body

    private func label(_ text: String, size: CGFloat = NSFont.systemFontSize,
                       color: NSColor = .labelColor, bold: Bool = false,
                       wrap: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        l.textColor = color
        if let w = wrap {
            l.lineBreakMode = .byWordWrapping
            l.usesSingleLineMode = false
            l.preferredMaxLayoutWidth = w
        }
        return l
    }

    private func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    /// Credential sources offered for this account's provider, in the order a
    /// user is most likely to want them.
    private func availableSources() -> [CredentialSource] {
        switch account.provider {
        case .claude:
            return [.claudeCodeKeychain, .appKeychain(id: account.id.uuidString), .file(path: "")]
        case .openAI:
            return [.codexDefault, .file(path: "")]
        }
    }

    private func sourceTitle(_ s: CredentialSource) -> String {
        switch s {
        case .claudeCodeKeychain: return "Claude Code credential (macOS Keychain)"
        case .appKeychain: return "Imported credential (this app's Keychain entry)"
        case .file: return "Credential file at a custom path"
        case .codexDefault: return "Codex / ChatGPT default (~/.codex/auth.json)"
        }
    }

    private func sameKind(_ a: CredentialSource, _ b: CredentialSource) -> Bool {
        switch (a, b) {
        case (.claudeCodeKeychain, .claudeCodeKeychain), (.codexDefault, .codexDefault),
             (.appKeychain, .appKeychain), (.file, .file):
            return true
        default: return false
        }
    }

    private func buildBody() -> NSView {
        nameField = NSTextField(string: account.displayName)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        enabledBox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
        enabledBox.state = account.enabled ? .on : .off

        sourcePopup = NSPopUpButton()
        for s in availableSources() { sourcePopup.addItem(withTitle: sourceTitle(s)) }
        sourcePopup.selectItem(at: availableSources().firstIndex { sameKind($0, account.credentialSource) } ?? 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)

        sourceDetail = label("", size: 11, color: .secondaryLabelColor, wrap: 420)
        statusLabel = label("", size: 11, color: .secondaryLabelColor, wrap: 420)

        let chooseFile = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile))
        chooseFile.bezelStyle = .rounded
        chooseFile.controlSize = .small
        let useDefault = NSButton(title: "Use Default", target: self, action: #selector(useDefaultSource))
        useDefault.bezelStyle = .rounded
        useDefault.controlSize = .small
        let importBtn = NSButton(title: "Import Credential…", target: self, action: #selector(importCredential))
        importBtn.bezelStyle = .rounded
        importBtn.controlSize = .small

        // Reset behaviour
        preferProviderBox = NSButton(checkboxWithTitle: "Use the provider's reset time when it reports one",
                                     target: self, action: #selector(resetControlsChanged))
        preferProviderBox.state = account.resetOverrides.preferProviderReset ? .on : .off

        useWeeklyBox = NSButton(checkboxWithTitle: "Weekly reset fallback",
                                target: self, action: #selector(resetControlsChanged))
        useWeeklyBox.state = account.resetOverrides.weekly != nil ? .on : .off

        weekdayPopup = NSPopUpButton()
        for i in 1...7 { weekdayPopup.addItem(withTitle: WeeklyResetRule.mondayNames[i] ?? "") }
        weekdayPopup.selectItem(at: (account.resetOverrides.weekly?.weekday ?? 2) - 1)

        hourField = NSTextField(string: String(format: "%02d", account.resetOverrides.weekly?.hour ?? 2))
        hourField.alignment = .right
        hourField.translatesAutoresizingMaskIntoConstraints = false
        hourField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        minuteField = NSTextField(string: String(format: "%02d", account.resetOverrides.weekly?.minute ?? 0))
        minuteField.alignment = .right
        minuteField.translatesAutoresizingMaskIntoConstraints = false
        minuteField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // Notifications
        customThresholdBox = NSButton(checkboxWithTitle: "Use a custom warning threshold",
                                      target: self, action: #selector(thresholdControlsChanged))
        customThresholdBox.state = account.notificationThresholdPercent != nil ? .on : .off
        thresholdField = NSTextField(string: "\(account.notificationThresholdPercent ?? coordinator.settings.warningThresholdPercent)")
        thresholdField.alignment = .right
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 54).isActive = true

        let save = NSButton(title: isNew ? "Add Account" : "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        var footer: [NSView] = [cancel, save]
        if !isNew {
            let remove = NSButton(title: "Remove Account", target: self, action: #selector(removeTapped))
            remove.bezelStyle = .rounded
            footer.insert(remove, at: 0)
        }

        let stack = NSStackView(views: [
            label("Display Name", size: 12, bold: true),
            nameField,
            hstack([label("Provider: \(account.provider.displayName)", size: 12), enabledBox]),

            label("Credential Source", size: 12, bold: true),
            sourcePopup,
            sourceDetail,
            statusLabel,
            hstack([chooseFile, useDefault, importBtn]),

            label("Reset Behaviour", size: 12, bold: true),
            preferProviderBox,
            useWeeklyBox,
            hstack([weekdayPopup, label("at"), hourField, label(":"), minuteField,
                    label("(\(TimeZone.current.identifier))", size: 11, color: .secondaryLabelColor)]),

            label("Notifications", size: 12, bold: true),
            customThresholdBox,
            hstack([label("Warn at"), thresholdField, label("% used")]),

            hstack(footer),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])

        updateSourceLabels()
        resetControlsChanged()
        thresholdControlsChanged()
        return container
    }

    // MARK: - Credential source

    private func currentSelectedSource() -> CredentialSource {
        let choices = availableSources()
        let idx = min(max(0, sourcePopup.indexOfSelectedItem), choices.count - 1)
        switch choices[idx] {
        case .file:
            return .file(path: pendingFilePath ?? filePathFromAccount() ?? "")
        case .appKeychain:
            return .appKeychain(id: account.id.uuidString)
        case let other:
            return other
        }
    }

    private func filePathFromAccount() -> String? {
        if case .file(let p) = account.credentialSource { return p }
        return nil
    }

    @objc private func sourceChanged() { updateSourceLabels() }

    private func updateSourceLabels() {
        let source = currentSelectedSource()
        switch source {
        case .file(let path):
            sourceDetail.stringValue = path.isEmpty
                ? "No file chosen yet. Use “Choose File…”."
                : (path as NSString).abbreviatingWithTildeInPath
        case .appKeychain:
            let present = Keychain.exists(service: AppInfo.appKeychainService,
                                          account: account.id.uuidString)
            sourceDetail.stringValue = present
                ? "A credential is stored for this account in the macOS Keychain."
                : "No credential imported yet. Use “Import Credential…”."
        default:
            sourceDetail.stringValue = source.locationLabel
        }

        // Status is computed from the source being *considered*, so the sheet
        // tells you whether a choice will work before you commit to it.
        var probe = account
        probe.credentialSource = source
        let status = ProviderRegistry.provider(for: account.provider).credentialStatus(for: probe)
        statusLabel.stringValue = "Status: \(status.displayName)"
        statusLabel.textColor = status == .detected ? .systemGreen
            : (status == .expired ? .systemOrange : .secondaryLabelColor)
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = account.provider == .openAI
            ? "Choose a Codex auth.json to read. This file is only ever read, never written."
            : "Choose a JSON file holding a Claude credential. It is only ever read."
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            if self.account.provider == .openAI,
               case .failure(let error) = CodexCredentialStore.validate(path: url.path) {
                self.presentError(error.message)
                return
            }
            self.pendingFilePath = url.path
            let choices = self.availableSources()
            if let idx = choices.firstIndex(where: { if case .file = $0 { return true }; return false }) {
                self.sourcePopup.selectItem(at: idx)
            }
            self.updateSourceLabels()
        }
    }

    @objc private func useDefaultSource() {
        pendingFilePath = nil
        let choices = availableSources()
        let defaultIndex = choices.firstIndex { source in
            switch (source, account.provider) {
            case (.claudeCodeKeychain, .claude), (.codexDefault, .openAI): return true
            default: return false
            }
        } ?? 0
        sourcePopup.selectItem(at: defaultIndex)
        updateSourceLabels()
    }

    /// Import a credential into this app's own Keychain entry.
    ///
    /// This is how a second Claude account coexists with the first: Claude Code
    /// keeps exactly one credential in its own Keychain item, so a second
    /// account needs somewhere else to live. The value is typed into a secure
    /// field and written straight to the Keychain — it is never held in user
    /// defaults, never written to a file, and never logged.
    @objc private func importCredential() {
        let alert = NSAlert()
        alert.messageText = "Import a Claude credential"
        alert.informativeText = """
            Paste the credential JSON for this account (the object containing \
            "claudeAiOauth"). It is written straight into the macOS Keychain \
            under this app's own entry and is never stored anywhere else.

            Sign in to the second account with Claude Code, copy its Keychain \
            item, then sign back in to the first — this app keeps its own copy \
            so the two no longer overwrite each other.
            """
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            let value = input.stringValue
            guard ClaudeCredentials.parse(json: value) != nil else {
                self.presentError("That does not look like a Claude credential. Expected JSON "
                                + "with an accessToken field.")
                return
            }
            guard ClaudeCredentialStore.importCredential(value, forAccountID: self.account.id) else {
                self.presentError("Could not write to the Keychain.")
                return
            }
            self.pendingImportedJSON = nil   // written already; nothing kept in memory
            let choices = self.availableSources()
            if let idx = choices.firstIndex(where: { if case .appKeychain = $0 { return true }; return false }) {
                self.sourcePopup.selectItem(at: idx)
            }
            self.updateSourceLabels()
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not use that credential"
        alert.informativeText = message
        alert.beginSheetModal(for: sheet, completionHandler: nil)
    }

    // MARK: - Reset controls

    @objc private func resetControlsChanged() {
        let useWeekly = useWeeklyBox.state == .on
        weekdayPopup.isEnabled = useWeekly
        hourField.isEnabled = useWeekly
        minuteField.isEnabled = useWeekly
    }

    @objc private func thresholdControlsChanged() {
        thresholdField.isEnabled = customThresholdBox.state == .on
    }

    // MARK: - Save

    @objc private func saveTapped() {
        var updated = account
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.displayName = name.isEmpty ? account.displayName : name
        updated.enabled = enabledBox.state == .on

        let source = currentSelectedSource()
        if case .file(let path) = source {
            guard !path.isEmpty else {
                presentError("Choose a credential file first, or pick another source.")
                return
            }
            if account.provider == .openAI, case .failure(let error) = CodexCredentialStore.validate(path: path) {
                presentError(error.message)
                return
            }
        }
        updated.credentialSource = source

        var overrides = ResetOverrides()
        overrides.preferProviderReset = preferProviderBox.state == .on
        if useWeeklyBox.state == .on {
            overrides.weekly = WeeklyResetRule(weekday: weekdayPopup.indexOfSelectedItem + 1,
                                               hour: Int(hourField.stringValue) ?? 0,
                                               minute: Int(minuteField.stringValue) ?? 0)
        } else {
            overrides.weekly = nil
        }
        updated.resetOverrides = overrides

        updated.notificationThresholdPercent = customThresholdBox.state == .on
            ? Int(thresholdField.stringValue).map { min(100, max(1, $0)) }
            : nil

        onSave?(updated)
        close()
    }

    @objc private func cancelTapped() { close() }

    @objc private func removeTapped() {
        let alert = NSAlert()
        alert.messageText = "Remove “\(account.displayName)”?"
        alert.informativeText = "Only a credential copy this app imported is deleted. "
            + "Claude Code's and the ChatGPT app's own credentials are untouched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            self.onDelete?(self.account.id)
            self.close()
        }
    }
}
