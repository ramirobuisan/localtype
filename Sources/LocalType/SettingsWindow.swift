import AppKit

private final class Trampoline: NSObject {
    let f: (Any?) -> Void
    init(_ f: @escaping (Any?) -> Void) { self.f = f }
    @objc func fire(_ sender: Any?) { f(sender) }
}

private final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    static let shared = SettingsWindow()

    private let pages = ["General", "Context", "Personalization", "Shortcuts", "Battery", "App Settings", "Statistics"]
    private let symbols = ["gearshape", "text.viewfinder", "wand.and.stars", "command", "battery.100", "slider.horizontal.3", "chart.bar"]

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let scroll = NSScrollView()
    private var retained: [AnyObject] = []
    private var textBindings: [ObjectIdentifier: (String) -> Void] = [:]
    private let lengths: [(String, Int)] = [("Short (~1 – 2 words)", 6), ("Medium (~2 – 4 words)", 12),
                                            ("Long (a phrase)", 32), ("Extra long (a sentence)", 64)]

    func show(page: Int = 0) {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        sidebar.selectRowIndexes([page], byExtendingSelection: false)
        select(page)
    }

    // MARK: Window

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "LocalType Settings"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 700, height: 420)
        w.delegate = self
        w.center()

        let col = NSTableColumn(identifier: .init("s")); col.width = 160
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 30
        sidebar.dataSource = self
        sidebar.delegate = self

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        let sbScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 600))
        sbScroll.autoresizingMask = [.height]
        sbScroll.documentView = sidebar
        sbScroll.drawsBackground = false
        sbScroll.hasVerticalScroller = false

        scroll.frame = NSRect(x: 180, y: 0, width: 640, height: 600)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        cv.addSubview(sbScroll); cv.addSubview(scroll)
        w.contentView = cv
        w.setContentSize(NSSize(width: 820, height: 600))
        window = w
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let img = NSImageView(image: NSImage(systemSymbolName: symbols[row], accessibilityDescription: nil) ?? NSImage())
        img.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let l = NSTextField(labelWithString: pages[row])
        let s = NSStackView(views: [img, l]); s.spacing = 8; s.alignment = .centerY
        return s
    }
    func tableViewSelectionDidChange(_ n: Notification) { if sidebar.selectedRow >= 0 { select(sidebar.selectedRow) } }

    private func select(_ i: Int) {
        retained = []; textBindings = [:]
        var sections: [NSView]
        switch pages[i] {
        case "General": sections = general()
        case "Context": sections = context()
        case "Personalization": sections = personalization()
        case "Shortcuts": sections = shortcuts()
        case "Battery": sections = battery()
        case "App Settings": sections = appSettings()
        default: sections = statistics()
        }
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        for v in sections { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        scroll.contentView.scroll(to: .zero)
    }

    // MARK: Row builders

    private func action(_ f: @escaping (Any?) -> Void) -> Trampoline { let t = Trampoline(f); retained.append(t); return t }

    private func row(_ title: String, _ desc: String?, _ control: NSView?, indent: Bool = false) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        var labels: [NSView] = [t]
        if let desc {
            let d = NSTextField(wrappingLabelWithString: desc)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labels.append(d)
        }
        let left = NSStackView(views: labels)
        left.orientation = .vertical; left.alignment = .leading; left.spacing = 3
        var views: [NSView] = [left]
        if let control {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            views += [spacer, control]
        }
        let h = NSStackView(views: views)
        h.orientation = .horizontal; h.alignment = .centerY; h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 10, left: indent ? 36 : 14, bottom: 10, right: 14)
        return h
    }

    private func card(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (i, r) in rows.enumerated() {
            if i > 0 { let sep = NSBox(); sep.boxType = .separator; views.append(sep) }
            views.append(r)
        }
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 0
        for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        let box = CardView()
        s.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: box.topAnchor),
            s.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    private func section(_ title: String?, _ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        if let title {
            let l = NSTextField(labelWithString: title)
            l.font = .boldSystemFont(ofSize: 12); l.textColor = .secondaryLabelColor
            views.append(l)
        }
        let c = card(rows)
        views.append(c)
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 6
        c.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func toggle(_ title: String, _ desc: String?, indent: Bool = false, get: @escaping () -> Bool,
                        set: @escaping (Bool) -> Void) -> NSView {
        let sw = NSSwitch()
        sw.state = get() ? .on : .off
        sw.target = action { s in set((s as? NSSwitch)?.state == .on) }
        sw.action = #selector(Trampoline.fire(_:))
        return row(title, desc, sw, indent: indent)
    }

    private func popup(_ title: String, _ desc: String?, items: [String], selected: Int, set: @escaping (Int) -> Void) -> NSView {
        let p = NSPopUpButton()
        p.addItems(withTitles: items)
        p.selectItem(at: max(0, min(selected, items.count - 1)))
        p.target = action { s in set((s as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        p.action = #selector(Trampoline.fire(_:))
        return row(title, desc, p)
    }

    private func button(_ title: String, _ desc: String?, _ label: String, _ f: @escaping () -> Void) -> NSView {
        let b = NSButton(title: label, target: action { _ in f() }, action: #selector(Trampoline.fire(_:)))
        b.bezelStyle = .rounded
        return row(title, desc, b)
    }

    private func recorder(_ title: String, _ desc: String, get: @escaping () -> Shortcut?, set: @escaping (Shortcut?) -> Void,
                          indent: Bool = false) -> NSView {
        let r = ShortcutRecorder()
        r.value = get()
        r.onChange = set
        retained.append(r)
        return row(title, desc, r, indent: indent)
    }

    private func textArea(height: CGFloat, text: String, onChange: @escaping (String) -> Void) -> NSView {
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.string = text
        tv.delegate = self
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        textBindings[ObjectIdentifier(tv)] = onChange
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.heightAnchor.constraint(equalToConstant: height).isActive = true
        let h = NSStackView(views: [sv])
        h.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 14, right: 14)
        sv.widthAnchor.constraint(equalTo: h.widthAnchor, constant: -28).isActive = true
        return h
    }

    func textDidChange(_ n: Notification) {
        guard let tv = n.object as? NSTextView, let f = textBindings[ObjectIdentifier(tv)] else { return }
        f(tv.string)
    }

    // MARK: Pages

    private func general() -> [NSView] {
        let store = currentStore()
        let modelPopup = NSPopUpButton()
        let fill = { (list: [InstalledModel]?) in
            modelPopup.removeAllItems()
            let names = (list ?? []).map { $0.name }
            modelPopup.addItems(withTitles: names)
            if let i = names.firstIndex(where: { store.isActive($0) }) { modelPopup.selectItem(at: i) }
            modelPopup.menu?.addItem(.separator())
            let m = NSMenuItem(title: "Manage models…", action: nil, keyEquivalent: "")
            modelPopup.menu?.addItem(m)
        }
        store.list(fill)
        modelPopup.target = action { [weak modelPopup] _ in
            guard let p = modelPopup, let title = p.titleOfSelectedItem else { return }
            if title == "Manage models…" { ModelsWindow.shared.show(); return }
            store.activeName = title
        }
        modelPopup.action = #selector(Trampoline.fire(_:))

        return [
            section(nil, [
                toggle("Launch automatically at login", nil, get: { Settings.launchAtLogin }, set: { Settings.launchAtLogin = $0 }),
                toggle("Show menu bar icon", "Display the LocalType icon in the menu bar. If hidden, reopen the app to get back here.",
                       get: { Settings.showMenuBarIcon }, set: { Settings.showMenuBarIcon = $0 }),
            ]),
            section("AI Settings", [
                row("AI model", Settings.backend == "embedded"
                    ? "Built-in engine — runs entirely inside the app." : "Using Ollama at \(Settings.endpoint).", modelPopup),
                button("Model files", "Open the folder containing downloaded models.", "Reveal in Finder") {
                    NSWorkspace.shared.open(GGUFStore.directory)
                },
                button("Download or import models", "Get models for the built-in engine, or switch to Ollama.", "Manage…") {
                    ModelsWindow.shared.show()
                },
            ]),
            section("Completion Settings", [
                toggle("Enable completions by default",
                       "When disabled, completions are turned off for all apps unless individually enabled per app in the App Settings pane.",
                       get: { Settings.enabledByDefault }, set: { Settings.enabledByDefault = $0 }),
                toggle("Complete inside existing text",
                       "Normally LocalType suggests only at the end of a line. Turn this on to also get suggestions when there is still text after the cursor on the same line.",
                       get: { Settings.completeInside }, set: { Settings.completeInside = $0 }),
                popup("Maximum completion length",
                      "Controls how long generated completions can be. Medium is recommended: longer completions are slower and more likely to drift from your intent — the next-word shortcut lets you take just part of them.",
                      items: lengths.map { $0.0 },
                      selected: lengths.enumerated().min { abs($0.element.1 - Settings.maxTokens) < abs($1.element.1 - Settings.maxTokens) }?.offset ?? 1,
                      set: { Settings.maxTokens = self.lengths[$0].1 }),
            ]),
            section("Privacy", [
                row("Nothing leaves your Mac", "Completions run on the built-in engine. There are no analytics, crash reports or accounts. Only a model download or an Ollama server you configure uses the network.", nil),
            ]),
            section("Emoji", [
                toggle("Emoji completion",
                       "Type a colon and part of a name, like :fire or :thumbs_up, to get an emoji. The accept key inserts it; the next-word key shows the next match. Emoji you use often come first.",
                       get: { Settings.emojiCompletion }, set: { Settings.emojiCompletion = $0 }),
            ]),
            section("Autocorrect", [
                toggle("Don't show completions when typo suspected",
                       "Hides the completion when the word you're typing looks misspelled, so LocalType doesn't extend a typo. It uses the macOS spell checker and isn't a full spell-check.",
                       get: { Settings.typoGuard }, set: { Settings.typoGuard = $0 }),
                toggle("Show suggested fixes", "When a likely correction is available, offer it (orange ✎) and let the accept key replace the typo.",
                       indent: true, get: { Settings.suggestFixes }, set: { Settings.suggestFixes = $0 }),
            ]),
        ]
    }

    private func context() -> [NSView] {
        [
            section("Screen Settings", [
                toggle("Use screen content for context",
                       "Reads the text in the window you're typing in (an email you're replying to, a chat, a document) so completions fit the conversation. The window is captured and read with on-device text recognition; nothing is saved or sent anywhere. Needs Screen Recording permission.",
                       get: { Settings.useScreen }, set: { on in
                           Settings.useScreen = on
                           ScreenContext.shared.clear()
                           ScreenContext.shared.prewarm()
                           if on, !ScreenContext.permitted { ScreenContext.requestPermission() }
                           self.select(1)
                       }),
                Settings.useScreen
                    ? (ScreenContext.permitted
                        ? row("Screen Recording", "Granted.", nil, indent: true)
                        : button("Screen Recording", "Not granted yet. Allow LocalType in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen LocalType.",
                                 "Open Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        })
                    : row("Tip", "Turn it off in apps with sensitive content from App Settings, or with the per-app shortcut.", nil, indent: true),
            ]),
            section("Clipboard Settings", [
                toggle("Use clipboard for context",
                       "When enabled, the first 400 characters of your clipboard text are added to the prompt so completions can reflect what you're working with. It's processed locally and never sent anywhere.",
                       get: { Settings.useClipboard }, set: { Settings.useClipboard = $0 }),
            ]),
        ]
    }

    private func personalization() -> [NSView] {
        let count = NSTextField(labelWithString: "")
        let updateCount = { count.stringValue = "\(History.shared.count) texts have been recorded so far." }
        updateCount()
        let slider = NSSlider(value: Settings.personalization, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.target = action { s in Settings.personalization = (s as? NSSlider)?.doubleValue ?? 0.5 }
        slider.action = #selector(Trampoline.fire(_:))
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let sliderRow = NSStackView(views: [NSTextField(labelWithString: "Off"), slider, NSTextField(labelWithString: "Max")])
        sliderRow.spacing = 6

        let existing = row("Existing data", nil, nil)
        _ = existing
        let del = NSButton(title: "Delete All…", target: action { _ in
            let a = NSAlert()
            a.messageText = "Delete all recorded writing?"
            a.informativeText = "This removes the local history used for personalization. It can't be undone."
            a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { History.shared.deleteAll(); updateCount() }
        }, action: #selector(Trampoline.fire(_:)))
        del.bezelStyle = .rounded
        let existingRow = NSStackView(views: [count, NSView(), del])
        existingRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        existingRow.orientation = .horizontal

        let reset = NSButton(title: "Reset to Default", target: action { _ in
            Settings.instructions = ""; self.select(2)
        }, action: #selector(Trampoline.fire(_:)))
        reset.controlSize = .small

        return [
            section("Typing History", [
                toggle("Record your writing for personalization",
                       "LocalType can record sentences you write in fields where it suggests text, so completions can echo your own words and phrases. Recorded text is stored only on this Mac (~/Library/Application Support/LocalType/history.json, readable only by you, not encrypted) and is never sent anywhere. Don't enable this if you work with sensitive information.",
                       get: { Settings.recordWriting }, set: { Settings.recordWriting = $0 }),
                toggle("Record text even when you accept no suggestion",
                       "When disabled, LocalType records only text where you accepted at least one completion.",
                       indent: true, get: { Settings.recordWithoutAccept }, set: { Settings.recordWithoutAccept = $0 }),
                row("Personalize word choice",
                    "Shows the model a few of your past sentences that resemble what you're typing. Higher values show more; too many may occasionally bias toward a less fitting word. Slightly slower, since the prompt changes each time.",
                    sliderRow, indent: true),
                existingRow,
            ]),
            section("Custom AI Instructions", [
                row("Custom AI Instructions", "Describe how you write: your occupation, languages, tone. A few sentences work best; keep it short — it is added to every prompt.", reset),
                textArea(height: 110, text: Settings.instructions) { Settings.instructions = $0 },
            ]),
        ]
    }

    private func shortcuts() -> [NSView] {
        [
            section(nil, [
                recorder("Trigger full completion", "Accepts the entire completion at once. Default: Tab.",
                         get: { Settings.keyAcceptAll }, set: { Settings.keyAcceptAll = $0 }),
                recorder("Complete only the next word",
                         "Press repeatedly to insert only the first few words, then resume typing yourself. Surprisingly effective in practice.",
                         get: { Settings.keyAcceptWord }, set: { Settings.keyAcceptWord = $0 }),
                toggle("Include trailing space", "Accepting a single word also inserts the space after it.", indent: true,
                       get: { Settings.includeTrailingSpace }, set: { Settings.includeTrailingSpace = $0 }),
                toggle("Include trailing punctuation", "Punctuation attached to a word (like a period) is accepted along with it.", indent: true,
                       get: { Settings.includeTrailingPunct }, set: { Settings.includeTrailingPunct = $0 }),
            ]),
            section(nil, [
                popup("When you press Escape",
                      "Only changes what Escape does while a suggestion is showing. Once it clears a suggestion, a second press goes to the app.",
                      items: ["Dismiss suggestion", "Pause completions for a few seconds"],
                      selected: Settings.escapePauses ? 1 : 0, set: { Settings.escapePauses = $0 == 1 }),
                recorder("Force-activate completions", "Some fields don't report typing; this requests a completion right now.",
                         get: { Settings.keyForce }, set: { Settings.keyForce = $0 }),
                recorder("Temporarily toggle completions in the current app",
                         "Turns completions off for 5 minutes in the frontmost app, or back on if currently disabled.",
                         get: { Settings.keyToggleApp }, set: { Settings.keyToggleApp = $0 }),
                recorder("Toggle completions globally", "Disables completions everywhere until you press it again.",
                         get: { Settings.keyToggleGlobal }, set: { Settings.keyToggleGlobal = $0 }),
            ]),
            section(nil, [row("Tip", "Click a shortcut, press the new keys. Esc cancels, ⌫ clears it.", nil)]),
        ]
    }

    private func battery() -> [NSView] {
        [
            section("Power", [
                toggle("Pause on battery power", "Turns completions off whenever the Mac isn't plugged in.",
                       get: { Settings.pauseOnBattery }, set: { Settings.pauseOnBattery = $0 }),
                toggle("Pause in Low Power Mode", "Skip suggestions when macOS Low Power Mode is on.",
                       get: { Settings.pauseLowPower }, set: { Settings.pauseLowPower = $0 }),
            ]),
        ]
    }

    private func appSettings() -> [NSView] {
        let listKey = Settings.enabledByDefault ? "Disabled apps" : "Enabled apps"
        let current = Settings.enabledByDefault ? Settings.disabledApps : Settings.enabledApps
        let apply: (String) -> Void = { text in
            let ids = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if Settings.enabledByDefault { Settings.disabledApps = ids } else { Settings.enabledApps = ids }
        }
        let area = textArea(height: 130, text: current.joined(separator: "\n"), onChange: apply)
        let tv = ((area as? NSStackView)?.arrangedSubviews.first as? NSScrollView)?.documentView as? NSTextView

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let pop = NSPopUpButton()
        pop.addItem(withTitle: "Add a running app…")
        for a in apps { pop.addItem(withTitle: a.localizedName ?? a.bundleIdentifier!) }
        pop.target = action { [weak pop] _ in
            guard let p = pop, p.indexOfSelectedItem > 0 else { return }
            let id = apps[p.indexOfSelectedItem - 1].bundleIdentifier!
            var list = (Settings.enabledByDefault ? Settings.disabledApps : Settings.enabledApps)
            if !list.contains(id) { list.append(id) }
            if Settings.enabledByDefault { Settings.disabledApps = list } else { Settings.enabledApps = list }
            tv?.string = list.joined(separator: "\n")
            p.selectItem(at: 0)
        }
        pop.action = #selector(Trampoline.fire(_:))

        return [
            section(listKey, [
                row(listKey, Settings.enabledByDefault
                    ? "LocalType is on everywhere except these apps. One bundle ID per line."
                    : "LocalType is off everywhere except these apps (see “Enable completions by default”). One bundle ID per line.", pop),
                area,
            ]),
        ]
    }

    private func statistics() -> [NSView] {
        let rate = Settings.shown > 0 ? String(format: "%.0f%%", Double(Settings.accepted) / Double(Settings.shown) * 100) : "–"
        return [
            section("Usage (stored only on this Mac)", [
                row("Suggestions shown", nil, NSTextField(labelWithString: "\(Settings.shown)")),
                row("Suggestions accepted", nil, NSTextField(labelWithString: "\(Settings.accepted)")),
                row("Acceptance rate", nil, NSTextField(labelWithString: rate)),
                row("Words inserted", nil, NSTextField(labelWithString: "\(Settings.wordsAccepted)")),
                row("Typo fixes applied", nil, NSTextField(labelWithString: "\(Settings.fixesApplied)")),
                row("Emoji inserted", nil, NSTextField(labelWithString: "\(Settings.emojiInserted)")),
                button("Reset statistics", nil, "Reset…") { Settings.resetStats(); self.select(6) },
            ]),
        ]
    }

    func windowWillClose(_ notification: Notification) { retained = []; textBindings = [:] }
}
