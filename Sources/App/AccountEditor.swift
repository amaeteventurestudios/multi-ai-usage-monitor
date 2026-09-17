import AppKit

/// Editor for one saved account.
///
/// Deliberately small. Everything about *getting* a credential now lives in the
/// guided onboarding flow, so this pane is only about what the user decides:
/// what to call the account, whether it is on, when its windows reset and how
/// loudly it should warn. Changing the credential is one button that hands back
/// to that same guided flow.
final class AccountEditorController: NSObject {

    var onSave: ((AIAccount) -> Void)?
    var onDelete: ((UUID) -> Void)?
    /// Asks the settings window to run the guided reconnect flow for this
    /// account — the editor never touches credentials itself.
    var onReconnect: ((AIAccount) -> Void)?

    private var account: AIAccount
    private let coordinator: UsageCoordinator

    private var sheet: NSWindow!
    var sheetWindow: NSWindow? { sheet }

    private var nameField: NSTextField!
    private var shortNameField: NSTextField!
    private var enabledBox: NSButton!
    private var preferProviderBox: NSButton!
    private var useWeeklyBox: NSButton!
    private var weekdayPopup: NSPopUpButton!
    private var hourField: NSTextField!
    private var minuteField: NSTextField!
    private var customThresholdBox: NSButton!
    private var thresholdField: NSTextField!

    init(account: AIAccount, coordinator: UsageCoordinator) {
        self.account = account
        self.coordinator = coordinator
        super.init()
    }

    // MARK: - Presentation

    func beginSheet(on parent: NSWindow) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 470),
                         styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Edit Account"
        sheet.contentView = buildBody()
        parent.beginSheet(sheet, completionHandler: nil)
        WindowBackground.apply(opacity: coordinator.settings.backgroundOpacity, to: sheet)
    }

    private func close() { sheet.sheetParent?.endSheet(sheet) }

    // MARK: - Builders

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

    private func buildBody() -> NSView {
        // Identity, stated as fact rather than as something to edit.
        let identityRows: [NSView]
        if let identity = account.identity, identity.isIdentified {
            var rows: [NSView] = [
                label(identity.email ?? "Confirmed by \(account.provider.displayName)",
                      size: 13, bold: true),
            ]
            if let subtitle = identity.subtitle {
                rows.append(label(subtitle, size: 11, color: .secondaryLabelColor))
            }
            rows.append(label("Confirmed by \(account.provider.displayName).",
                              size: 11, color: .secondaryLabelColor))
            identityRows = rows
        } else {
            identityRows = [
                label("Identity not verified", size: 13, bold: true),
                label("\(account.provider.displayName) did not say which account this credential "
                    + "belongs to. Any name below is a local label you chose, not something the "
                    + "provider confirmed.", size: 11, color: .secondaryLabelColor, wrap: 440),
            ]
        }

        nameField = NSTextField(string: account.customDisplayName ?? "")
        nameField.placeholderString = AccountNaming.displayName(provider: account.provider,
                                                               identity: account.identity,
                                                               custom: nil)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        shortNameField = NSTextField(string: account.customShortName ?? "")
        shortNameField.placeholderString = ShortName.derive(provider: account.provider,
                                                            identity: account.identity)
        shortNameField.translatesAutoresizingMaskIntoConstraints = false
        shortNameField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        enabledBox = NSButton(checkboxWithTitle: "Show this account", target: nil, action: nil)
        enabledBox.state = account.enabled ? .on : .off

        let status = ProviderRegistry.provider(for: account.provider).credentialStatus(for: account)
        let statusText = status == .detected ? "Connected" : "Reconnect required"
        let statusLabel = label("Credential: \(account.credentialSource.kindLabel) · \(statusText)",
                                size: 11,
                                color: status == .detected ? .secondaryLabelColor : .systemOrange,
                                wrap: 440)
        let reconnect = NSButton(title: "Reconnect…", target: self, action: #selector(reconnectTapped))
        reconnect.bezelStyle = .rounded
        reconnect.controlSize = .small

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
        thresholdField = NSTextField(
            string: "\(account.notificationThresholdPercent ?? coordinator.settings.warningThresholdPercent)")
        thresholdField.alignment = .right
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 54).isActive = true

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        let remove = NSButton(title: "Remove Account", target: self, action: #selector(removeTapped))
        remove.bezelStyle = .rounded

        var views: [NSView] = [label("Account", size: 12, bold: true)]
        views.append(contentsOf: identityRows)
        views.append(contentsOf: [
            label("Name shown in the menu", size: 12, bold: true),
            nameField,
            label("Leave empty to use the detected account name.", size: 11,
                  color: .secondaryLabelColor),

            label("Menu Bar Name", size: 12, bold: true),
            shortNameField,
            label("Short label used in the menu bar. Leave empty to derive one from the "
                + "account. E-mail addresses are never shown up there.",
                  size: 11, color: .secondaryLabelColor, wrap: 440),

            enabledBox,

            label("Credential", size: 12, bold: true),
            statusLabel,
            hstack([reconnect]),

            label("Reset Behaviour", size: 12, bold: true),
            preferProviderBox,
            useWeeklyBox,
            hstack([weekdayPopup, label("at"), hourField, label(":"), minuteField,
                    label("(\(TimeZone.current.identifier))", size: 11, color: .secondaryLabelColor)]),

            label("Notifications", size: 12, bold: true),
            customThresholdBox,
            hstack([label("Warn at"), thresholdField, label("% used")]),

            hstack([remove, cancel, save]),
        ])

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
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

        resetControlsChanged()
        thresholdControlsChanged()
        return container
    }

    // MARK: - Actions

    @objc private func resetControlsChanged() {
        let useWeekly = useWeeklyBox.state == .on
        weekdayPopup.isEnabled = useWeekly
        hourField.isEnabled = useWeekly
        minuteField.isEnabled = useWeekly
    }

    @objc private func thresholdControlsChanged() {
        thresholdField.isEnabled = customThresholdBox.state == .on
    }

    @objc private func reconnectTapped() {
        let account = self.account
        close()
        onReconnect?(account)
    }

    @objc private func saveTapped() {
        var updated = account
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.customDisplayName = typed.isEmpty ? nil : typed

        let short = shortNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.customShortName = short.isEmpty ? nil : String(short.prefix(ShortName.maximumLength))

        updated.enabled = enabledBox.state == .on

        var overrides = ResetOverrides()
        overrides.preferProviderReset = preferProviderBox.state == .on
        if useWeeklyBox.state == .on {
            overrides.weekly = WeeklyResetRule(weekday: weekdayPopup.indexOfSelectedItem + 1,
                                               hour: Int(hourField.stringValue) ?? 0,
                                               minute: Int(minuteField.stringValue) ?? 0)
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
        alert.informativeText = "Only the credential copy this app imported is deleted. "
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
