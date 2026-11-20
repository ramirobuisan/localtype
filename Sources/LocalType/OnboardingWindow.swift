import AppKit

/// First-launch setup: one page with a live checklist (permissions, model) and the optional extras.
/// Also reachable later from the menu-bar menu ("Setup…").
final class OnboardingWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = OnboardingWindow()

    private var window: NSWindow?
    private var timer: Timer?
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: "Grant Access…", target: nil, action: nil)
    private let modelStatus = NSTextField(labelWithString: "")
    private let modelButton = NSButton(title: "Choose a Model…", target: nil, action: nil)
    private let screenSwitch = NSSwitch()
    private let screenStatus = NSTextField(labelWithString: "")
    private let emojiSwitch = NSSwitch()
    private let style = NSTextView()
    private let practice = NSTextView()

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: Layout

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Welcome to LocalType"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self

        // Header: app icon, title, one-line intro, centered.
        let icon = NSImageView(image: NSApp.applicationIconImage ?? iconTile("text.cursor", .systemIndigo, size: 80))
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let title = NSTextField(labelWithString: "Welcome to LocalType")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .center
        let intro = NSTextField(wrappingLabelWithString:
            "Suggestions to finish your sentences in any app, from a model that runs entirely on this Mac. Two things are required; the rest can wait or be changed later in Settings.")
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        let header = NSStackView(views: [icon, title, intro])
        header.orientation = .vertical; header.alignment = .centerX; header.spacing = 8
        header.setCustomSpacing(14, after: icon)
        intro.widthAnchor.constraint(lessThanOrEqualToConstant: 470).isActive = true

        axButton.target = self; axButton.action = #selector(grantAX)
        modelButton.target = self; modelButton.action = #selector(chooseModel)
        screenSwitch.target = self; screenSwitch.action = #selector(screenToggled)
        emojiSwitch.target = self; emojiSwitch.action = #selector(emojiToggled)
        screenSwitch.controlSize = .small
        emojiSwitch.controlSize = .small
        for b in [axButton, modelButton] { b.bezelStyle = .push }
        for l in [axStatus, modelStatus, screenStatus] { l.font = .systemFont(ofSize: 11, weight: .medium) }

        style.isRichText = false
        style.font = .systemFont(ofSize: 13)
        style.string = Settings.instructions
        style.delegate = self
        style.isVerticallyResizable = true
        style.autoresizingMask = [.width]
        style.textContainer?.widthTracksTextView = true
        style.textContainerInset = NSSize(width: 4, height: 6)
        style.drawsBackground = false
        let styleScroll = NSScrollView()
        styleScroll.documentView = style
        styleScroll.hasVerticalScroller = true
        styleScroll.drawsBackground = false
        styleScroll.borderType = .noBorder
        styleScroll.heightAnchor.constraint(equalToConstant: 66).isActive = true
        let placeholderNote = label("For example: “I'm Laura, a nurse. I write in English and Spanish, friendly but short.”", bold: false)
        let styleBox = NSStackView(views: [styleScroll, placeholderNote])
        styleBox.orientation = .vertical; styleBox.alignment = .leading; styleBox.spacing = 6
        styleBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 14)
        styleScroll.widthAnchor.constraint(equalTo: styleBox.widthAnchor, constant: -24).isActive = true

        // "Try it": the one own text box LocalType suggests in (read directly, never recorded).
        practice.identifier = AX.practiceID
        practice.isRichText = false
        practice.font = .systemFont(ofSize: 14)
        practice.textContainerInset = NSSize(width: 4, height: 6)
        practice.drawsBackground = false
        practice.isVerticallyResizable = true
        practice.autoresizingMask = [.width]
        practice.textContainer?.widthTracksTextView = true
        practice.isAutomaticSpellingCorrectionEnabled = false
        practice.isAutomaticTextCompletionEnabled = false
        let practiceScroll = NSScrollView()
        practiceScroll.documentView = practice
        practiceScroll.drawsBackground = false
        practiceScroll.borderType = .noBorder
        practiceScroll.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let tips = label("Type something, e.g. “Thanks for the update, I'll”, and pause: the suggestion appears in grey. Each ⇥ takes a word, ⌥⇥ all of it, Esc dismisses. :fire gives 🔥. Needs Accessibility access.", bold: false)
        let practiceBox = NSStackView(views: [practiceScroll, tips])
        practiceBox.orientation = .vertical; practiceBox.alignment = .leading; practiceBox.spacing = 6
        practiceBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 14)
        practiceScroll.widthAnchor.constraint(equalTo: practiceBox.widthAnchor, constant: -24).isActive = true

        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        done.bezelStyle = .push
        done.controlSize = .large
        done.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let footer = NSStackView(views: [NSView(), done])
        footer.alignment = .centerY

        let views: [NSView] = [
            header,
            group("Required", [
                step("accessibility", .systemBlue, "Accessibility access",
                     "Lets LocalType see the text before your cursor and type the suggestions you accept.", axStatus, axButton),
                step("cpu", .systemPurple, "A language model", OnboardingWindow.modelHint, modelStatus, modelButton),
            ]),
            group("Optional", [
                step("text.viewfinder", .systemTeal, "Screen context",
                     "Reads the window you're typing in with on-device text recognition so replies fit the conversation. Needs Screen Recording.",
                     screenStatus, screenSwitch),
                step("face.smiling", .systemYellow, "Emoji completion", "Type :fire or :thumbs_up to get 🔥 or 👍.", nil, emojiSwitch),
            ]),
            group("How you write", [styleBox]),
            group("Try it", [practiceBox]),
            footer,
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(20, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 32, bottom: 22, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true }

        let cv = NSView()
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            cv.widthAnchor.constraint(equalToConstant: 600),
        ])
        w.contentView = cv
        window = w
    }

    /// A titled card holding rows separated by inset dividers.
    private func group(_ title: String, _ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let d = Divider()
                let wrap = NSStackView(views: [d])
                wrap.edgeInsets = NSEdgeInsets(top: 0, left: 54, bottom: 0, right: 14)
                d.widthAnchor.constraint(equalTo: wrap.widthAnchor, constant: -68).isActive = true
                views.append(wrap)
            }
            views.append(r)
        }
        let inner = NSStackView(views: views)
        inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 0
        for v in views { v.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true }
        let card = CardView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let headWrap = NSStackView(views: [heading])
        headWrap.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        let s = NSStackView(views: [headWrap, card])
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 8
        card.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func label(_ s: String, bold: Bool) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 11)
        if !bold { l.textColor = .secondaryLabelColor }
        return l
    }

    private static var modelHint: String {
        switch Settings.backend {
        case "mlxserve": return "Uses a chat model from MLX-Serve; nothing is downloaded. Smaller models answer faster."
        case "ollama": return "Uses a model from your Ollama server."
        default: return "Runs on this Mac with the built-in engine. Qwen2.5 3B is a good start (2.1 GB)."
        }
    }

    private func step(_ symbol: String, _ color: NSColor, _ title: String, _ desc: String, _ status: NSTextField?, _ control: NSView) -> NSView {
        let tile = NSImageView(image: iconTile(symbol, color, size: 28))
        tile.widthAnchor.constraint(equalToConstant: 28).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let t = NSTextField(wrappingLabelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        var texts: [NSView] = [t, label(desc, bold: false)]
        if let status { texts.append(status) }
        let col = NSStackView(views: texts)
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [tile, col, spacer, control])
        row.alignment = .centerY; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return row
    }

    // MARK: State

    private func refresh() {
        let trusted = AX.trusted(prompt: false)
        axStatus.stringValue = trusted ? "✓ Granted" : "Not granted yet"
        axStatus.textColor = trusted ? .systemGreen : .systemOrange
        axButton.isHidden = trusted

        let store = currentStore()
        let active = store.activeName
        store.list { [weak self] list in
            guard let self else { return }
            let have = list?.contains { store.isActive($0.name) } ?? false
            self.modelStatus.stringValue = have ? "✓ Using \(active)" : "No model selected yet"
            self.modelStatus.textColor = have ? .systemGreen : .systemOrange
            self.modelButton.title = have ? "Change…" : "Choose a Model…"
        }

        screenSwitch.state = Settings.useScreen ? .on : .off
        let permitted = ScreenContext.permitted
        screenStatus.isHidden = !Settings.useScreen
        screenStatus.stringValue = permitted ? "✓ Screen Recording granted"
            : "Allow LocalType under Screen & System Audio Recording, then reopen LocalType."
        screenStatus.textColor = permitted ? .systemGreen : .systemOrange
        emojiSwitch.state = Settings.emojiCompletion ? .on : .off
    }

    @objc private func grantAX() {
        _ = AX.trusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func chooseModel() { ModelsWindow.shared.show() }

    @objc private func screenToggled() {
        Settings.useScreen = screenSwitch.state == .on
        ScreenContext.shared.clear()
        ScreenContext.shared.prewarm()
        if Settings.useScreen, !ScreenContext.permitted { ScreenContext.requestPermission() }
        refresh()
    }

    @objc private func emojiToggled() { Settings.emojiCompletion = emojiSwitch.state == .on }

    func textDidChange(_ n: Notification) { Settings.instructions = style.string }

    @objc private func finish() {
        Settings.onboardingDone = true
        window?.close()
    }

    func windowWillClose(_ n: Notification) {
        timer?.invalidate(); timer = nil
        Settings.onboardingDone = true
    }
}
