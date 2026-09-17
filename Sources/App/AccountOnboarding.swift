import AppKit

/// The guided "Add Account" / "Reconnect" flow.
///
/// Four steps, the same for every provider: choose where the credential comes
/// from, detect who it belongs to, confirm, save. Nothing in it asks the user
/// about Keychain services, JSON shapes, token formats or provider account ids —
/// those stay behind the scenes where they belong.
final class AccountOnboardingController: NSObject {

    /// Reconnecting reuses the whole flow; only the wording and the final step
    /// differ, because an existing account keeps everything except its
    /// credential.
    enum Mode {
        case add(ProviderKind)
        case reconnect(AIAccount)

        var provider: ProviderKind {
            switch self {
            case .add(let p): return p
            case .reconnect(let a): return a.provider
            }
        }
    }

    var onFinished: ((AIAccount) -> Void)?

    private let mode: Mode
    private let coordinator: UsageCoordinator

    private var sheet: NSWindow!
    var sheetWindow: NSWindow? { sheet }

    private var body: NSStackView!
    private var methods: [CredentialMethod] = []
    private var selectedMethodIndex = 0
    /// A file the user picked for a file-based method.
    private var chosenFilePath: String?
    /// Filled in once detection succeeds.
    private var detected: (identity: AccountIdentity, source: CredentialSource)?
    /// Local label, offered only when the provider would not name the account.
    private var fallbackLabelField: NSTextField?

    init(mode: Mode, coordinator: UsageCoordinator) {
        self.mode = mode
        self.coordinator = coordinator
        self.methods = ProviderRegistry.provider(for: mode.provider).credentialMethods()
        super.init()
    }

    // MARK: - Presentation

    func beginSheet(on parent: NSWindow) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
                         styleMask: [.titled], backing: .buffered, defer: false)
        switch mode {
        case .add(let provider): sheet.title = "Add \(provider.displayName) Account"
        case .reconnect(let account): sheet.title = "Reconnect \(account.displayName)"
        }
        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        body.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        sheet.contentView = container
        showChooseStep()
        parent.beginSheet(sheet, completionHandler: nil)
        WindowBackground.apply(opacity: coordinator.settings.backgroundOpacity, to: sheet)
    }

    private func close() { sheet.sheetParent?.endSheet(sheet) }

    // MARK: - Small builders

    private func label(_ text: String, size: CGFloat = NSFont.systemFontSize,
                       color: NSColor = .labelColor, bold: Bool = false,
                       wrap: CGFloat? = 440) -> NSTextField {
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

    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if primary { b.keyEquivalent = "\r" }
        return b
    }

    private func setBody(_ views: [NSView]) {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views { body.addArrangedSubview(v) }
    }

    private func stepHeading(_ step: Int, _ title: String) -> NSStackView {
        let s = NSStackView(views: [
            label("STEP \(step) OF 3", size: 10, color: .secondaryLabelColor, wrap: nil),
            label(title, size: 15, bold: true),
        ])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        return s
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 8
        return s
    }

    // MARK: - Step 1: where does the credential come from

    private func showChooseStep() {
        var views: [NSView] = [stepHeading(1, "Choose the account to add")]

        if case .reconnect(let account) = mode {
            views = [stepHeading(1, "Reconnect this account")]
            views.append(label("Only the credential is replaced. The name, reset schedule, "
                             + "position and notification settings for “\(account.displayName)” "
                             + "are all kept.", size: 11, color: .secondaryLabelColor))
        }

        for (i, method) in methods.enumerated() {
            let radio = NSButton(radioButtonWithTitle: method.title, target: self,
                                 action: #selector(methodSelected(_:)))
            radio.tag = i
            radio.state = i == selectedMethodIndex ? .on : .off
            radio.font = NSFont.systemFont(ofSize: 13, weight: method.isPrimary ? .semibold : .regular)
            views.append(radio)

            let detail = label(method.detail, size: 11, color: .secondaryLabelColor)
            views.append(detail)

            if method.requiresFileChoice && i == selectedMethodIndex {
                let chooser = button("Choose File…", #selector(chooseFile))
                chooser.controlSize = .small
                let path = chosenFilePath.map { ($0 as NSString).abbreviatingWithTildeInPath }
                views.append(hstack([chooser,
                                     label(path ?? "No file chosen", size: 11,
                                           color: .secondaryLabelColor, wrap: 280)]))
            }
        }

        views.append(hstack([button("Cancel", #selector(cancelTapped)),
                             button("Continue", #selector(detectTapped), primary: true)]))
        setBody(views)
    }

    @objc private func methodSelected(_ sender: NSButton) {
        selectedMethodIndex = sender.tag
        showChooseStep()
    }

    @objc private func chooseFile() {
        let provider = mode.provider
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = provider == .openAI
            ? "Choose a Codex auth.json to read. It is only ever read, never written."
            : "Choose a JSON file holding a Claude credential. It is only ever read."
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.chosenFilePath = url.path
            self.showChooseStep()
        }
    }

    // MARK: - Step 2: detect

    private func resolvedSource() -> CredentialSource? {
        let method = methods[min(selectedMethodIndex, methods.count - 1)]
        if method.requiresFileChoice {
            guard let path = chosenFilePath, !path.isEmpty else { return nil }
            return .file(path: path)
        }
        return method.source
    }

    @objc private func detectTapped() {
        guard let source = resolvedSource() else {
            showChooseStep()
            presentInline("Choose a credential file first.")
            return
        }
        showDetectingStep()
        ProviderRegistry.provider(for: mode.provider)
            .discoverIdentity(source: source) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let identity):
                        self.detected = (identity, source)
                        self.showConfirmStep(identity: identity)
                    case .failure(let error):
                        self.showFailureStep(error)
                    }
                }
            }
    }

    private func showDetectingStep() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        setBody([
            stepHeading(2, "Checking with \(mode.provider.displayName)…"),
            hstack([spinner, label("Confirming the credential and reading which account it is.",
                                   size: 12, color: .secondaryLabelColor, wrap: 400)]),
        ])
    }

    // MARK: - Step 3: confirm

    private func showConfirmStep(identity: AccountIdentity) {
        var views: [NSView] = [stepHeading(3, identity.isIdentified
                                            ? "Account detected"
                                            : "Account identity could not be verified")]

        func row(_ name: String, _ value: String) -> NSStackView {
            let s = NSStackView(views: [
                label(name.uppercased(), size: 10, color: .secondaryLabelColor, wrap: nil),
                label(value, size: 13, bold: true),
            ])
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 1
            return s
        }

        views.append(row("Provider", mode.provider.displayName))

        if identity.isIdentified {
            views.append(row("Account", identity.email ?? "Confirmed, but not named"))
            if let plan = identity.planLabel { views.append(row("Plan", plan)) }
            if let org = identity.organizationName, org != identity.email {
                views.append(row("Organisation", org))
            }
            views.append(label("Saved as: \(previewName(identity: identity))",
                               size: 11, color: .secondaryLabelColor))
        } else {
            views.append(label("\(mode.provider.displayName) accepted this credential but would "
                             + "not say which account it belongs to. You can give it a local name "
                             + "instead — that name is just a label you chose, not something the "
                             + "provider confirmed.",
                               size: 11, color: .secondaryLabelColor))
            let field = NSTextField(string: "")
            field.placeholderString = "Local name for this account"
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            fallbackLabelField = field
            views.append(field)
        }

        if case .add = mode {
            views.append(label("The credential is copied into this app's own Keychain entry, so "
                             + "you can sign a different account into \(toolName()) afterwards "
                             + "and this one keeps reporting.",
                               size: 11, color: .secondaryLabelColor))
        }

        let saveTitle: String
        if case .reconnect = mode { saveTitle = "Reconnect" } else { saveTitle = "Save Account" }
        views.append(hstack([button("Back", #selector(backTapped)),
                             button("Cancel", #selector(cancelTapped)),
                             button(saveTitle, #selector(saveTapped), primary: true)]))
        setBody(views)
    }

    private func toolName() -> String {
        mode.provider == .claude ? "Claude Code" : "ChatGPT or Codex"
    }

    private func previewName(identity: AccountIdentity) -> String {
        AccountNaming.displayName(provider: mode.provider, identity: identity, custom: nil)
    }

    // MARK: - Failure

    private func showFailureStep(_ error: AccountError) {
        var views: [NSView] = [stepHeading(2, "That did not work")]
        views.append(label(error.message, size: 12))
        if let recovery = error.recovery {
            views.append(label(recovery, size: 11, color: .secondaryLabelColor))
        }
        views.append(hstack([button("Back", #selector(backTapped)),
                             button("Cancel", #selector(cancelTapped)),
                             button("Try Again", #selector(detectTapped), primary: true)]))
        setBody(views)
    }

    private func presentInline(_ message: String) {
        body.addArrangedSubview(label("⚠︎ \(message)", size: 11, color: .systemOrange))
    }

    // MARK: - Actions

    @objc private func backTapped() { showChooseStep() }
    @objc private func cancelTapped() { close() }

    @objc private func saveTapped() {
        guard let detected = detected else { showChooseStep(); return }
        let custom = fallbackLabelField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .add:
            let result = coordinator.saveOnboardedAccount(provider: mode.provider,
                                                          identity: detected.identity,
                                                          source: detected.source)
            switch result {
            case .success(let account):
                if let custom = custom, !custom.isEmpty {
                    coordinator.store.rename(id: account.id, to: custom)
                }
                onFinished?(coordinator.store.account(id: account.id) ?? account)
                close()
            case .failure(let error):
                showFailureStep(error)
            }

        case .reconnect(let account):
            let result = coordinator.reconnect(accountID: account.id,
                                               identity: detected.identity,
                                               source: detected.source)
            switch result {
            case .success(let updated):
                onFinished?(updated)
                close()
            case .failure(let error):
                showFailureStep(error)
            }
        }
    }
}
