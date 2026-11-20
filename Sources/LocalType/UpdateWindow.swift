import AppKit

/// "A new version is available": release notes, then Install and Relaunch with progress.
final class UpdateWindow: NSObject, NSWindowDelegate {
    static let shared = UpdateWindow()

    private var window: NSWindow?
    private var release: Updates.Release?
    private var updater: Updater?
    private let heading = NSTextField(labelWithString: "")
    private let subheading = NSTextField(wrappingLabelWithString: "")
    private let notes = NSTextView()
    private let bar = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let install = NSButton(title: "Install and Relaunch", target: nil, action: nil)
    private let later = NSButton(title: "Later", target: nil, action: nil)
    private let github = NSButton(title: "View on GitHub", target: nil, action: nil)

    func show(_ release: Updates.Release) {
        if window == nil { build() }
        if updater == nil { self.release = release; fill() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Software Update"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        subheading.font = .systemFont(ofSize: 12)
        subheading.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [heading, subheading])
        titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 3
        let header = NSStackView(views: [icon, titles]); header.alignment = .centerY; header.spacing = 14

        notes.isEditable = false
        notes.drawsBackground = false
        notes.textContainerInset = NSSize(width: 10, height: 10)
        notes.isVerticallyResizable = true
        notes.autoresizingMask = [.width]
        notes.textContainer?.widthTracksTextView = true
        let sv = NSScrollView()
        sv.documentView = notes
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.heightAnchor.constraint(equalToConstant: 230).isActive = true
        let card = CardView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: card.topAnchor, constant: 2), sv.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
            sv.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2), sv.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -2),
        ])

        bar.style = .bar
        bar.minValue = 0; bar.maxValue = 1
        bar.isHidden = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        install.target = self; install.action = #selector(installNow)
        install.keyEquivalent = "\r"
        later.target = self; later.action = #selector(close)
        later.keyEquivalent = "\u{1b}"
        github.target = self; github.action = #selector(openGitHub)
        for b in [install, later, github] { b.bezelStyle = .push }
        let buttons = NSStackView(views: [github, NSView(), later, install])
        buttons.spacing = 8

        let views: [NSView] = [header, card, bar, status, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(18, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 38, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        let cv = NSView()
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor), stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            cv.widthAnchor.constraint(equalToConstant: 560),
        ])
        w.contentView = cv
        window = w
    }

    private func fill() {
        guard let r = release else { return }
        heading.stringValue = "LocalType \(r.version) is available"
        subheading.stringValue = "You have \(Updates.current). The update installs in place and LocalType reopens by itself; your settings and permissions stay."
        // Release notes as rendered Markdown (bold, code, links), keeping their line structure; headings become
        // bold lines and list dashes become bullets.
        let text = r.notes.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").map { line -> String in
            var l = line
            if let m = l.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { l.removeSubrange(m); return "**\(l)**" }
            if let m = l.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) { l.replaceSubrange(m, with: "•  ") }
            return l
        }.joined(separator: "\n")
        let md = (try? NSAttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? NSAttributedString(string: text)
        let styled = NSMutableAttributedString(attributedString: md)
        let all = NSRange(location: 0, length: styled.length)
        styled.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        styled.enumerateAttribute(.font, in: all) { value, range, _ in
            let bold = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
            styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular), range: range)
        }
        notes.textStorage?.setAttributedString(styled)
        bar.isHidden = true
        status.stringValue = r.zip == nil ? "This release has no download attached; use View on GitHub." : ""
        install.isEnabled = r.zip != nil
        later.isEnabled = true
    }

    @objc private func installNow() {
        guard let r = release else { return }
        install.isEnabled = false
        later.isEnabled = false
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let u = Updater()
        updater = u
        u.install(r) { [weak self] step in
            guard let self else { return }
            switch step {
            case .downloading(let f):
                if let f { self.bar.isIndeterminate = false; self.bar.doubleValue = f
                    self.status.stringValue = "Downloading… \(Int(f * 100))%" }
                else { self.status.stringValue = "Downloading…" }
            case .verifying:
                self.bar.isIndeterminate = true; self.bar.startAnimation(nil)
                self.status.stringValue = "Verifying the download…"
            case .installing:
                self.status.stringValue = "Installing…"
            case .relaunching:
                self.status.stringValue = "Relaunching…"
            case .failed(let why):
                self.updater = nil
                self.bar.isHidden = true
                self.status.stringValue = why
                self.status.textColor = .systemOrange
                self.install.isEnabled = true
                self.later.isEnabled = true
            }
        }
    }

    @objc private func openGitHub() { if let r = release { NSWorkspace.shared.open(r.url) } }
    @objc private func close() { window?.close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { updater == nil }   // not mid-install
}
