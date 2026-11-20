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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to LocalType"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let title = NSTextField(labelWithString: "Welcome to LocalType")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString:
            "LocalType suggests how to finish your sentence in any app, using a model that runs entirely on this Mac. Two things are required; the rest is optional and can be changed later in Settings.")
        intro.textColor = .secondaryLabelColor

        axButton.target = self; axButton.action = #selector(grantAX)
        modelButton.target = self; modelButton.action = #selector(chooseModel)
        screenSwitch.target = self; screenSwitch.action = #selector(screenToggled)
        emojiSwitch.target = self; emojiSwitch.action = #selector(emojiToggled)
        for l in [axStatus, modelStatus, screenStatus] { l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor }

        style.isRichText = false
        style.font = .systemFont(ofSize: 12)
        style.string = Settings.instructions
        style.delegate = self
        style.isVerticallyResizable = true
        style.autoresizingMask = [.width]
        style.textContainer?.widthTracksTextView = true
        let styleScroll = NSScrollView()
        styleScroll.documentView = style
        styleScroll.hasVerticalScroller = true
        styleScroll.borderType = .bezelBorder
        styleScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let tips = NSTextField(wrappingLabelWithString:
            "Using it: type in any app and pause briefly. ⇥ accepts the suggestion, ⌥⇥ accepts one word, Esc dismisses. Type :name for an emoji. The menu-bar icon (a text cursor) has Settings and Models.")
        tips.font = .systemFont(ofSize: 11)
        tips.textColor = .secondaryLabelColor

        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        let footer = NSStackView(views: [NSView(), done])

        let howTitle = label("How you write (optional)", bold: true)
        let views: [NSView] = [
            title, intro,
            step("1", "Accessibility access", "Lets LocalType see the text before your cursor and type accepted suggestions.", axStatus, axButton),
            step("2", "A language model", "Runs on this Mac with the built-in engine. Qwen2.5 3B is a good start (2.1 GB).", modelStatus, modelButton),
            step("3", "Screen context (optional)", "Reads the window you're typing in with on-device text recognition so replies fit the conversation. Needs Screen Recording permission.", screenStatus, screenSwitch),
            step("4", "Emoji completion (optional)", "Type :fire or :thumbs_up to get 🔥 or 👍.", nil, emojiSwitch),
            howTitle,
            label("Your languages, tone or job, in a sentence or two. Added to every prompt.", bold: false),
            styleScroll,
            tips, footer,
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: howTitle)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true }

        let cv = NSView()
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            cv.widthAnchor.constraint(equalToConstant: 580),
        ])
        w.contentView = cv
        window = w
    }

    private func label(_ s: String, bold: Bool) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 11)
        if !bold { l.textColor = .secondaryLabelColor }
        return l
    }

    private func step(_ n: String, _ title: String, _ desc: String, _ status: NSTextField?, _ control: NSView) -> NSView {
        let badge = NSTextField(labelWithString: n)
        badge.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        badge.textColor = .controlAccentColor
        badge.widthAnchor.constraint(equalToConstant: 16).isActive = true
        var texts: [NSView] = [label(title, bold: true), label(desc, bold: false)]
        if let status { texts.append(status) }
        let col = NSStackView(views: texts)
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [badge, col, control])
        row.alignment = .centerY; row.spacing = 12
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
