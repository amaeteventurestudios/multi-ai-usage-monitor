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

    /// What the currently selected auto-detect method resolves to right now.
    ///
    /// Resolved *before* the user can continue, so nobody imports a credential
    /// without first seeing which account it actually is. That matters because
    /// these credentials belong to a specific tool's sign-in — Claude Code's
    /// terminal login, not claude.ai in a browser — and the two are easy to
    /// assume are the same.
    private enum Preflight {
        case checking
        case resolved(AccountIdentity)
        case failed(AccountError)
    }
    private var preflight: Preflight = .checking
    /// Generation counter so a slow check that the user has already moved past
    /// cannot overwrite a newer result.
    private var preflightToken = 0
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
        runPreflight()
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

        let method = currentMethod()
        if method.supportsPreflight {
            views.append(contentsOf: preflightViews(for: method))
        } else {
            views.append(contentsOf: fileChoiceViews(for: method))
        }

        // The other ways in, kept out of the way of the everyday one.
        let alternatives = methods.enumerated().filter { $0.offset != selectedMethodIndex }
        if !alternatives.isEmpty {
            let divider = NSBox(); divider.boxType = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            views.append(divider)
            divider.widthAnchor.constraint(equalToConstant: 440).isActive = true

            for (i, alternative) in alternatives {
                let link = NSButton(title: alternative.title, target: self,
                                    action: #selector(methodSelected(_:)))
                link.tag = i
                link.bezelStyle = .inline
                link.isBordered = false
                link.contentTintColor = .linkColor
                link.font = NSFont.systemFont(ofSize: 11)
                views.append(link)
            }
        }

        views.append(hstack([button("Cancel", #selector(cancelTapped))]))
        setBody(views)
    }

    /// The account this method resolves to, shown before anything is imported.
    private func preflightViews(for method: CredentialMethod) -> [NSView] {
        var views: [NSView] = []
        if let heading = method.preflightHeading {
            views.append(label(heading, size: 12, bold: true))
        }

        switch preflight {
        case .checking:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            views.append(hstack([spinner, label("Checking…", size: 12,
                                                color: .secondaryLabelColor, wrap: nil)]))

        case .resolved(let identity):
            views.append(label(identity.email ?? "Signed in, but this account is not named",
                               size: 15, bold: true))
            if let plan = identity.planLabel {
                views.append(label("Plan: \(plan)", size: 12, color: .secondaryLabelColor))
            }
            if let org = identity.organizationName, org != identity.email {
                views.append(label(org, size: 11, color: .secondaryLabelColor))
            }
            views.append(label("Credential source: \(method.sourceSummary)",
                               size: 11, color: .tertiaryLabelColor))

        case .failed(let error):
            views.append(label(error.message, size: 12, color: .systemOrange))
            if let recovery = error.recovery {
                views.append(label(recovery, size: 11, color: .secondaryLabelColor))
            }
        }

        // Always visible, in every state: what this credential actually is.
        if let disclaimer = method.disclaimer {
            views.append(label(disclaimer, size: 11, color: .secondaryLabelColor))
        }

        if case .resolved = preflight, let instruction = method.switchInstruction {
            views.append(label("If this is not the account you want: \(instruction)",
                               size: 11, color: .secondaryLabelColor))
        }

        var buttons: [NSView] = []
        if case .resolved = preflight {
            buttons.append(button("Use This Account", #selector(usePreflightAccount), primary: true))
        }
        let again = button("Check Again", #selector(checkAgainTapped))
        again.isEnabled = !isChecking
        buttons.append(again)
        views.append(hstack(buttons))
        return views
    }

    private var isChecking: Bool {
        if case .checking = preflight { return true }
        return false
    }

    /// The advanced path: pick a credential file, then continue.
    private func fileChoiceViews(for method: CredentialMethod) -> [NSView] {
        var views: [NSView] = [label(method.title, size: 12, bold: true),
                               label(method.detail, size: 11, color: .secondaryLabelColor)]
        let chooser = button("Choose File…", #selector(chooseFile))
        chooser.controlSize = .small
        let path = chosenFilePath.map { ($0 as NSString).abbreviatingWithTildeInPath }
        views.append(hstack([chooser,
                             label(path ?? "No file chosen", size: 11,
                                   color: .secondaryLabelColor, wrap: 280)]))
        let cont = button("Continue", #selector(detectTapped), primary: true)
        cont.isEnabled = chosenFilePath != nil
        views.append(hstack([cont]))
        return views
    }

    private func currentMethod() -> CredentialMethod {
        methods[min(max(0, selectedMethodIndex), methods.count - 1)]
    }

    // MARK: - Preflight

    /// Resolve who the selected method's credential belongs to.
    private func runPreflight() {
        let method = currentMethod()
        guard method.supportsPreflight else { return }
        preflightToken += 1
        let token = preflightToken
        preflight = .checking
        showChooseStep()

        ProviderRegistry.provider(for: mode.provider)
            .discoverIdentity(source: method.source) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self, token == self.preflightToken else { return }
                    switch result {
                    case .success(let identity):
                        self.preflight = .resolved(identity)
                    case .failure(let error):
                        self.preflight = .failed(error)
                    }
                    self.showChooseStep()
                }
            }
    }

    @objc private func checkAgainTapped() { runPreflight() }

    /// The account has already been resolved, so go straight to confirmation
    /// rather than asking the provider the same question twice.
    @objc private func usePreflightAccount() {
        guard case .resolved(let identity) = preflight else { return }
        detected = (identity, currentMethod().source)
        showConfirmStep(identity: identity)
    }

    @objc private func methodSelected(_ sender: NSButton) {
        selectedMethodIndex = sender.tag
        showChooseStep()
        runPreflight()
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
        guard let source = resolvedSource() else { showChooseStep(); return }
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
                             + "you can sign \(toolName()) in to a different account afterwards "
                             + "and this one keeps reporting.",
                               size: 11, color: .secondaryLabelColor))
        }
        if let disclaimer = currentMethod().disclaimer {
            views.append(label(disclaimer, size: 11, color: .secondaryLabelColor))
        }

        let saveTitle: String
        if case .reconnect = mode { saveTitle = "Reconnect" } else { saveTitle = "Save Account" }
        views.append(hstack([button("Back", #selector(backTapped)),
                             button("Cancel", #selector(cancelTapped)),
                             button(saveTitle, #selector(saveTapped), primary: true)]))
        setBody(views)
    }

    /// The tool whose credential this is — named exactly, never softened to
    /// "Claude" or "ChatGPT", which would point at a different sign-in.
    private func toolName() -> String {
        mode.provider == .claude ? "Claude Code" : "the ChatGPT app or Codex CLI"
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

    // MARK: - Actions

    @objc private func backTapped() {
        showChooseStep()
        runPreflight()
    }
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
