import AppKit

private final class Trampoline: NSObject {
    let f: (Any?) -> Void
    init(_ f: @escaping (Any?) -> Void) { self.f = f }
    @objc func fire(_ sender: Any?) { f(sender) }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    static let shared = SettingsWindow()

    private struct Page { let name: String; let symbol: String; let color: NSColor; let blurb: String }
    private let pageInfo: [Page] = [
        Page(name: "Setup", symbol: "checkmark", color: .systemBlue, blurb: "Permissions and everything LocalType needs to work well."),
        Page(name: "General", symbol: "gearshape.fill", color: .systemGray, blurb: "When and how suggestions appear, and which model writes them."),
        Page(name: "Context", symbol: "text.viewfinder", color: .systemTeal, blurb: "What LocalType may look at so suggestions fit what you're doing."),
        Page(name: "Personalization", symbol: "wand.and.stars", color: .systemPurple, blurb: "Make suggestions sound like you."),
        Page(name: "Emoji", symbol: "face.smiling", color: .systemYellow, blurb: "Emoji from :names and text emoticons."),
        Page(name: "Shortcuts", symbol: "command", color: .systemIndigo, blurb: "Keys to accept, dismiss and control suggestions."),
        Page(name: "Battery", symbol: "battery.100percent", color: .systemGreen, blurb: "Save power when your Mac isn't plugged in."),
        Page(name: "App Settings", symbol: "square.grid.2x2.fill", color: .systemPink, blurb: "Turn LocalType on or off for specific apps and websites."),
        Page(name: "Labs", symbol: "flask.fill", color: .systemOrange, blurb: "Experimental features: useful, but less polished than the rest."),
        Page(name: "Statistics", symbol: "chart.bar.fill", color: .systemCyan, blurb: "What LocalType has typed for you. Stored only on this Mac."),
        Page(name: "About", symbol: "info", color: .systemGray, blurb: "Version, updates and credits."),
    ]
    private var pages: [String] { pageInfo.map(\.name) }

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let scroll = NSScrollView()
    private var retained: [AnyObject] = []
    private var textBindings: [ObjectIdentifier: (String) -> Void] = [:]
    private let lengths: [(String, Int)] = [("Current word only", 0), ("Short (~1 – 2 words)", 6), ("Medium (~2 – 4 words)", 12),
                                            ("Long (a phrase)", 32), ("Extra long (a sentence)", 64)]

    /// By name, case-insensitive ("statistics", "App Settings", "app-settings").
    func show(page: String) {
        let key = page.lowercased().replacingOccurrences(of: "-", with: " ")
        show(page: pages.firstIndex { $0.lowercased() == key } ?? 1)
    }

    /// Rebuilds the visible page (after a setting changes what it shows).
    private func reload() { select(max(0, sidebar.selectedRow)) }

    func show(page: Int = 0) {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        sidebar.selectRowIndexes([page], byExtendingSelection: false)
        select(page)
    }

    // MARK: Window

    /// Standard sidebar layout (NSSplitViewController): full-height translucent sidebar, unified title bar.
    private func build() {
        let sidebarVC = NSViewController()
        let col = NSTableColumn(identifier: .init("s"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 32
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.dataSource = self
        sidebar.delegate = self
        let sbScroll = NSScrollView()
        sbScroll.documentView = sidebar
        sbScroll.drawsBackground = false
        sbScroll.hasVerticalScroller = false
        sidebarVC.view = sbScroll

        let contentVC = NSViewController()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        contentVC.view = scroll

        let split = NSSplitViewController()
        let sbItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sbItem.canCollapse = false
        sbItem.minimumThickness = 210
        sbItem.maximumThickness = 210
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 520
        contentItem.titlebarSeparatorStyle = .automatic   // a line only once content scrolls under the title bar
        sbItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(sbItem)
        split.addSplitViewItem(contentItem)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = split
        w.title = "LocalType Settings"
        w.titleVisibility = .hidden            // each page shows its own header
        w.toolbar = NSToolbar(identifier: "settings")
        w.toolbarStyle = .unifiedCompact
        w.titlebarSeparatorStyle = .automatic
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 460)
        w.setContentSize(NSSize(width: 860, height: 640))
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("LocalTypeSettings")
        window = w
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pageInfo.count }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let p = pageInfo[row]
        let cell = NSTableCellView()
        let img = NSImageView(image: iconTile(p.symbol, p.color, size: 22))
        let label = NSTextField(labelWithString: p.name)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        cell.imageView = img
        cell.textField = label     // NSTableCellView turns it white on the selected row
        for v in [img, label] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 22), img.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ n: Notification) { if sidebar.selectedRow >= 0 { select(sidebar.selectedRow) } }

    /// Icon, title and one-line description at the top of each page.
    private func header(_ p: Page) -> NSView {
        let img = NSImageView(image: iconTile(p.symbol, p.color, size: 38))
        img.widthAnchor.constraint(equalToConstant: 38).isActive = true
        img.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let title = NSTextField(labelWithString: p.name)
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let blurb = NSTextField(wrappingLabelWithString: p.blurb)
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [title, blurb])
        texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 2
        let h = NSStackView(views: [img, texts])
        h.alignment = .centerY; h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 4, right: 0)
        return h
    }

    private func select(_ i: Int) {
        retained = []; textBindings = [:]
        window?.title = pageInfo[i].name
        window?.subtitle = ""
        var sections: [NSView]
        switch pages[i] {
        case "Setup": sections = setup()
        case "Labs": sections = labs()
        case "About": sections = about()
        case "Emoji": sections = emojiPage()
        case "General": sections = general()
        case "Context": sections = context()
        case "Personalization": sections = personalization()
        case "Shortcuts": sections = shortcuts()
        case "Battery": sections = battery()
        case "App Settings": sections = appSettings()
        default: sections = statistics()
        }
        let all = [header(pageInfo[i])] + sections
        let stack = NSStackView(views: all)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.setCustomSpacing(18, after: all[0])
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 28, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        let clip = scroll.contentView
        // A centered column: comfortable to read on a wide window, filling a narrow one.
        let fill = stack.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -56)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            fill,
        ])
        for v in all { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Row builders

    private func action(_ f: @escaping (Any?) -> Void) -> Trampoline { let t = Trampoline(f); retained.append(t); return t }

    private func row(_ title: String, _ desc: String?, _ control: NSView?, indent: Bool = false) -> NSView {
        let t = NSTextField(wrappingLabelWithString: title)
        t.font = .systemFont(ofSize: 13)
        var labels: [NSView] = [t]
        if let desc {
            let d = NSTextField(wrappingLabelWithString: desc)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            labels.append(d)
        }
        for l in labels { l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let left = NSStackView(views: labels)
        left.orientation = .vertical; left.alignment = .leading; left.spacing = 3
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [left]
        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            // Long labels (model names) shouldn't squeeze the description into a sliver.
            if control is NSPopUpButton { control.widthAnchor.constraint(lessThanOrEqualToConstant: 270).isActive = true }
            views += [control]
        }
        let h = NSStackView(views: views)
        h.orientation = .horizontal; h.alignment = .centerY; h.spacing = 16
        h.distribution = .fill
        h.edgeInsets = NSEdgeInsets(top: 9, left: indent ? 34 : 14, bottom: 9, right: 14)
        h.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return h
    }

    private func card(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let d = Divider()
                let wrap = NSStackView(views: [d])
                wrap.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
                d.widthAnchor.constraint(equalTo: wrap.widthAnchor, constant: -28).isActive = true
                views.append(wrap)
            }
            views.append(r)
        }
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 0
        for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        let box = CardView()
        s.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            s.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    private func section(_ title: String?, _ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        if let title {
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            l.textColor = .labelColor
            let wrap = NSStackView(views: [l])
            wrap.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
            views.append(wrap)
        }
        let c = card(rows)
        views.append(c)
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 8
        c.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func toggle(_ title: String, _ desc: String?, indent: Bool = false, get: @escaping () -> Bool,
                        set: @escaping (Bool) -> Void) -> NSView {
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = get() ? .on : .off
        sw.target = action { s in set((s as? NSSwitch)?.state == .on) }
        sw.action = #selector(Trampoline.fire(_:))
        return row(title, desc, sw, indent: indent)
    }

    /// Borderless pop-up with chevrons, as in System Settings.
    private func styledPopup() -> NSPopUpButton {
        let p = NSPopUpButton()
        p.isBordered = false
        (p.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        p.font = .systemFont(ofSize: 13)
        (p.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        return p
    }

    private func popup(_ title: String, _ desc: String?, items: [String], selected: Int, set: @escaping (Int) -> Void) -> NSView {
        let p = styledPopup()
        p.addItems(withTitles: items)
        p.selectItem(at: max(0, min(selected, items.count - 1)))
        p.target = action { s in set((s as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        p.action = #selector(Trampoline.fire(_:))
        return row(title, desc, p)
    }

    private func button(_ title: String, _ desc: String?, _ label: String, _ f: @escaping () -> Void) -> NSView {
        let b = NSButton(title: label, target: action { _ in f() }, action: #selector(Trampoline.fire(_:)))
        b.bezelStyle = .push
        b.controlSize = .regular
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

    /// Green "✓ text" or orange "text", optionally followed by a button.
    private func status(_ ok: Bool, _ okText: String, _ badText: String, button: (String, () -> Void)? = nil) -> NSView {
        let l = NSTextField(labelWithString: ok ? "✓ " + okText : badText)
        l.textColor = ok ? .systemGreen : .systemOrange
        var views: [NSView] = [l]
        if !ok, let (title, f) = button {
            let b = NSButton(title: title, target: action { _ in f() }, action: #selector(Trampoline.fire(_:)))
            b.bezelStyle = .rounded
            views.append(b)
        }
        let st = NSStackView(views: views); st.spacing = 8
        return st
    }

    static var inlinePredictionOn: Bool {
        UserDefaults.standard.object(forKey: "NSAutomaticInlinePredictionEnabled") as? Bool ?? true
    }

    private func emojiPage() -> [NSView] {
        let tones = ["Neutral 👋", "Light 👋🏻", "Medium-light 👋🏼", "Medium 👋🏽", "Medium-dark 👋🏾", "Dark 👋🏿"]
        return [
            section(nil, [
                toggle("Emoji suggestions",
                       "Type “ :” for the emoji you use most, or keep typing a name to search (:fire, :thumbs_up, or :sweat_smile: with a closing colon). Tab inserts the emoji; ↓ and ↑ show the other matches. Search can miss; the macOS emoji picker (⌃⌘Space) is always there as a fallback.",
                       get: { Settings.emojiCompletion }, set: { Settings.emojiCompletion = $0 }),
                toggle("Turn emoticons into emoji",
                       "Typing a text emoticon such as :-)  ;-)  :(  or <3 offers the matching emoji. When off, only the colon search is left.",
                       indent: true, get: { Settings.emojiEmoticons }, set: { Settings.emojiEmoticons = $0 }),
            ]),
            section("Customization", [
                popup("Preferred skin tone", "Used for emoji that come in different skin tones.",
                      items: tones, selected: Settings.emojiSkinTone, set: { Settings.emojiSkinTone = $0 }),
                toggle("Also suggest the neutral variant", "Offers the default yellow version next to your preferred skin tone.",
                       indent: true, get: { Settings.emojiIncludeNeutral }, set: { Settings.emojiIncludeNeutral = $0 }),
                popup("Preferred gender", "For people emoji that have separate woman and man versions (police officer, firefighter, scientist…).",
                      items: ["Gender-neutral 🧑", "Woman 👩", "Man 👨"], selected: Settings.emojiGender,
                      set: { Settings.emojiGender = $0 }),
            ]),
        ]
    }

    private func about() -> [NSView] {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? iconTile("text.cursor", .systemIndigo, size: 64))
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "LocalType \(Updates.current)")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: "Build \(Updates.build). On-device autocomplete for any Mac app. An independent project, not affiliated with Cotypist.")
        sub.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [name, sub]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 4
        let header = NSStackView(views: [icon, texts]); header.spacing = 14
        header.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let status = NSTextField(wrappingLabelWithString: Settings.lastUpdateCheck == .distantPast ? "Not checked yet."
            : "Last checked \(DateFormatter.localizedString(from: Settings.lastUpdateCheck, dateStyle: .medium, timeStyle: .short)).")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
        checkNow.bezelStyle = .rounded
        checkNow.target = action { [weak checkNow] _ in
            checkNow?.isEnabled = false
            status.stringValue = "Checking…"
            Updates.check { outcome in
                checkNow?.isEnabled = true
                switch outcome {
                case .upToDate: status.stringValue = "LocalType \(Updates.current) is the latest version."
                case .failed(let why): status.stringValue = "Couldn't check: \(why)"
                case .available(let r):
                    status.stringValue = "LocalType \(r.version) is available."
                    let a = NSAlert()
                    a.messageText = "LocalType \(r.version) is available"
                    a.informativeText = "You have \(Updates.current). Open the release page to download it?"
                    a.addButton(withTitle: "Open Release Page"); a.addButton(withTitle: "Later")
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.url) }
                }
            }
        }
        checkNow.action = #selector(Trampoline.fire(_:))
        let checkRow = NSStackView(views: [status, NSView(), checkNow])
        checkRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        func credit(_ title: String, _ detail: String, _ url: String) -> NSView {
            button(title, detail, "Website") { NSWorkspace.shared.open(URL(string: url)!) }
        }
        return [
            section(nil, [header]),
            section("Updates", [
                checkRow,
                toggle("Check for updates automatically", "Looks for a new release on GitHub once a day. LocalType only tells you; it never installs anything by itself.",
                       get: { Settings.autoCheckUpdates }, set: { Settings.autoCheckUpdates = $0 }),
                button("Source code", "The project, its issues and its releases.", "Open GitHub") { NSWorkspace.shared.open(Updates.repoURL) },
            ]),
            section("Third-Party Acknowledgments", [
                credit("llama.cpp", "Built-in engine. MIT License, by the ggml authors.", "https://github.com/ggml-org/llama.cpp"),
                row("Models", "Each model has its own license: Gemma under the Gemma Terms of Use (Gemma 4: Apache 2.0), Qwen and others under Apache 2.0 or their own terms.", nil),
                row("MLX-Serve", "A separate app that LocalType talks to on this Mac; not bundled.", nil),
            ]),
        ]
    }

    private func labs() -> [NSView] {
        let chatNote = LLM.supportsLists ? nil
            : "Needs MLX-Serve or Ollama (Models…): the built-in engine only continues text."
        let syncStatus = NSTextField(wrappingLabelWithString: "")
        syncStatus.font = .systemFont(ofSize: 11)
        syncStatus.textColor = .secondaryLabelColor
        func describe(_ r: Sync.Result?) {
            if case .failed(let why)? = r { syncStatus.stringValue = why; syncStatus.textColor = .systemOrange; return }
            syncStatus.textColor = .secondaryLabelColor
            if !Sync.available { syncStatus.stringValue = "iCloud Drive isn't turned on for this Mac."; return }
            if Vault.syncKey == nil { syncStatus.stringValue = "No sync passphrase set yet."; return }
            var text = Sync.lastSync.map { "Last synced \(DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short))." } ?? "Not synced yet."
            if case .ok(let added, let macs)? = r { text += " \(macs) Mac\(macs == 1 ? "" : "s"); \(added) change\(added == 1 ? "" : "s") merged." }
            syncStatus.stringValue = text
        }
        describe(nil)
        let syncNow = NSButton(title: "Sync Now", target: action { _ in Sync.runInBackground { describe($0) } }, action: #selector(Trampoline.fire(_:)))
        syncNow.bezelStyle = .rounded
        let statusRow = NSStackView(views: [syncStatus, NSView(), syncNow])
        statusRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        return [
            section("Alternative Words", [
                popup("Show alternative suggestions",
                      "Offers other ways to continue under the cursor, either after a short pause on a suggestion or when you press the shortcut. Press 1–5 to insert one. Meant for the occasional wording hiccup, not for every word." + (chatNote.map { " " + $0 } ?? ""),
                      items: ["Don't show", "After a short pause", "Only with the shortcut"],
                      selected: Settings.alternativesMode, set: { Settings.alternativesMode = $0 }),
                recorder("Show alternatives now", "Opens the list for the suggestion on screen.",
                         get: { Settings.keyAlternatives }, set: { Settings.keyAlternatives = $0 }, indent: true),
            ]),
            section("Synonyms", [
                popup("Suggest synonyms for selected words",
                      "Select a word or short phrase to see synonyms that fit the sentence, either after a moment or when you press the shortcut. Press 1–5 to replace the selection." + (chatNote.map { " " + $0 } ?? ""),
                      items: ["Off", "Automatically", "Only with the shortcut"],
                      selected: Settings.synonymsMode, set: { Settings.synonymsMode = $0 }),
                recorder("Show synonyms now", "Looks up synonyms for the current selection.",
                         get: { Settings.keySynonyms }, set: { Settings.keySynonyms = $0 }, indent: true),
            ]),
            section("iCloud Sync", [
                toggle("Sync your typing history between your Macs",
                       "Your recorded writing (Personalization) is synced through iCloud Drive, end-to-end encrypted with a passphrase you choose and enter on each Mac. Apple only ever sees encrypted files; the passphrase isn't stored, only a key derived from it, in this Mac's Keychain. Deleting text on one Mac removes it on the others." + (Sync.available ? "" : " iCloud Drive must be on."),
                       get: { Settings.syncHistory }, set: { on in
                           Settings.syncHistory = on
                           if on, !Settings.recordWriting {
                               let a = NSAlert()
                               a.messageText = "Typing history is off"
                               a.informativeText = "There's nothing to sync until “Record your writing for personalization” is on (Personalization)."
                               a.runModal()
                           }
                           Sync.update(); self.reload()
                       }),
                button("Sync passphrase", Vault.syncKey == nil ? "Use the same passphrase (8+ characters) on every Mac."
                                                               : "Set. Changing it makes other Macs' files unreadable until you change it there too.",
                       Vault.syncKey == nil ? "Set Passphrase…" : "Change…") {
                    let a = NSAlert()
                    a.messageText = "Sync passphrase"
                    a.informativeText = "Enter the same passphrase on each Mac you want to sync. At least 8 characters. It can't be recovered: if you forget it, set a new one on every Mac."
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                    a.accessoryView = field
                    a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
                    a.window.initialFirstResponder = field
                    guard a.runModal() == .alertFirstButtonReturn else { return }
                    if Sync.setPassphrase(field.stringValue) { Sync.update(); self.reload() }
                    else {
                        let e = NSAlert(); e.messageText = "Use at least 8 characters."; e.runModal()
                    }
                },
                statusRow,
            ]),
        ]
    }

    private func setup() -> [NSView] {
        let ax = AX.trusted(prompt: false)
        let screen = ScreenContext.permitted
        let modelStatus = NSTextField(labelWithString: "Checking…")
        let store = currentStore()
        store.list { list in
            let have = list?.contains { store.isActive($0.name) } ?? false
            modelStatus.stringValue = have ? "✓ " + store.activeName : "No model selected"
            modelStatus.textColor = have ? .systemGreen : .systemOrange
            modelStatus.lineBreakMode = .byTruncatingMiddle
            modelStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        }
        let manage = NSButton(title: "Manage…", target: action { _ in ModelsWindow.shared.show() }, action: #selector(Trampoline.fire(_:)))
        manage.bezelStyle = .rounded
        let modelRow = NSStackView(views: [modelStatus, manage]); modelRow.spacing = 8
        let predictionOn = SettingsWindow.inlinePredictionOn
        let ready = ax && !predictionOn
        return [
            section(nil, [
                row(ready ? "All set" : "Almost there",
                    ready ? "LocalType is ready. The items below are here if you want to check or change them."
                          : "Fix the orange items below for LocalType to work well.", nil),
            ]),
            section("Required", [
                row("Accessibility permission", "Lets LocalType read the text before your cursor and type the suggestions you accept.",
                    status(ax, "Granted", "Not granted", button: ("Grant…", {
                        _ = AX.trusted(prompt: true)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }))),
                row("AI model", "The model that writes the suggestions.", modelRow),
            ]),
            section("Recommended", [
                row("Screen Recording permission",
                    "For screen context: the window you're typing in is read on this Mac to make suggestions fit. Nothing is stored or sent anywhere.",
                    status(screen, "Granted", "Not granted", button: ("Grant…", {
                        ScreenContext.requestPermission()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }))),
                row("macOS inline predictive text",
                    "macOS's own inline predictions compete with LocalType for the same spot and the same Tab key. Turn off “Show inline predictive text” in System Settings → Keyboard → Input Sources → Edit….",
                    status(!predictionOn, "Off", "On — conflicts", button: ("Open Keyboard Settings", {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }))),
                toggle("Clipboard context", "Adds the start of your clipboard text to the prompt so suggestions reflect what you're working with. Processed on this Mac only.",
                       get: { Settings.useClipboard }, set: { Settings.useClipboard = $0 }),
            ]),
        ]
    }

    private func general() -> [NSView] {
        let store = currentStore()
        let modelPopup = styledPopup()
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
        let recommendation = NSTextField(wrappingLabelWithString: "")
        recommendation.font = .systemFont(ofSize: 11)
        recommendation.textColor = .secondaryLabelColor
        let useRecommended = NSButton(title: "Use", target: nil, action: nil)
        useRecommended.bezelStyle = .rounded
        useRecommended.isHidden = true
        store.list { list in
            guard let rec = recommendedModel(list ?? [], backend: Settings.backend) else { return }
            let active = store.isActive(rec)
            recommendation.stringValue = active ? "You're using the model recommended for your Mac." : "Recommended for your Mac: \(rec)"
            useRecommended.isHidden = active
            useRecommended.target = self.action { _ in store.activeName = rec; self.reload() }
            useRecommended.action = #selector(Trampoline.fire(_:))
        }
        let star = NSImageView(image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) ?? NSImage())
        star.contentTintColor = .systemYellow
        star.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        recommendation.stringValue = recommendation.stringValue.replacingOccurrences(of: "★ ", with: "")
        recommendation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let recRow = NSStackView(views: [star, recommendation, NSView(), useRecommended])
        recRow.spacing = 6
        recRow.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        modelPopup.target = action { [weak modelPopup] _ in
            guard let p = modelPopup, let title = p.titleOfSelectedItem else { return }
            if title == "Manage models…" { ModelsWindow.shared.show(); return }
            store.activeName = title
        }
        modelPopup.action = #selector(Trampoline.fire(_:))

        return [
            section(nil, [
                toggle("Launch automatically at login", nil, get: { Settings.launchAtLogin }, set: { Settings.launchAtLogin = $0 }),
                toggle("Show accessory button",
                       "A small floating button at the corner of the text field you're typing in. It opens LocalType's menu right there: turn completions off for this app or website, open Settings, and more.",
                       get: { Settings.showAccessoryButton }, set: { Settings.showAccessoryButton = $0 }),
                toggle("Show menu bar icon", "Display the LocalType icon in the menu bar. If hidden, reopen the app to get back here.",
                       get: { Settings.showMenuBarIcon }, set: { Settings.showMenuBarIcon = $0 }),
            ]),
            section("Appearance", [
                popup("Suggestion style",
                      "Inline draws the suggestion as faded text in the field's own font, right where you type. Bubble shows it in a small box next to the cursor.",
                      items: ["Inline, in the field's font", "Bubble"], selected: Settings.suggestionStyle,
                      set: { Settings.suggestionStyle = $0 }),
            ]),
            section("AI Settings", [
                row("AI model", Settings.backend == "embedded" ? "Built-in engine — runs entirely inside the app."
                    : Settings.backend == "mlxserve" ? "MLX-Serve at \(Settings.mlxEndpoint). Smaller models answer faster."
                    : "Using Ollama at \(Settings.endpoint).", modelPopup),
                recRow,
                button("Model files", "Open the folder containing downloaded models.", "Reveal in Finder") {
                    NSWorkspace.shared.open(GGUFStore.directory)
                },
                button("Models", "Switch between MLX-Serve, the built-in engine and Ollama, or download a model.", "Manage…") {
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
                      "Controls how long generated completions can be. Medium is recommended: longer completions are slower and more likely to drift from your intent — the next-word shortcut lets you take just part of them. “Current word only” finishes the word you're typing and never suggests the next one: spelling help without writing suggestions.",
                      items: lengths.map { $0.0 },
                      selected: lengths.enumerated().min { abs($0.element.1 - Settings.maxTokens) < abs($1.element.1 - Settings.maxTokens) }?.offset ?? 1,
                      set: { Settings.maxTokens = self.lengths[$0].1 }),
            ]),
            section("Privacy", [
                row("Nothing leaves your Mac", "Completions run on the built-in engine. There are no analytics, crash reports or accounts. Only a model download or an Ollama server you configure uses the network.", nil),
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
                           self.reload()
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
            section("Appearance", [
                toggle("Use screenshots to improve suggestion appearance",
                       "Takes a tiny screenshot next to the cursor to match the field's background: readable contrast on any page, and a solid backing when a suggestion has to sit over text after the cursor. May briefly show the Screen Recording indicator in the menu bar.",
                       get: { Settings.matchAppearance }, set: { Settings.matchAppearance = $0 }),
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
            Settings.instructions = ""; self.reload()
        }, action: #selector(Trampoline.fire(_:)))
        reset.controlSize = .small

        return [
            section("Typing History", [
                toggle("Record your writing for personalization",
                       "LocalType can record sentences you write in fields where it suggests text, so completions can echo your own words and phrases. Recorded text is encrypted and stored only on this Mac (the key is in your Keychain); nothing is sent anywhere unless you turn on iCloud sync in Labs.",
                       get: { Settings.recordWriting }, set: { Settings.recordWriting = $0 }),
                toggle("Record text even when you accept no suggestion",
                       "When disabled, LocalType records only text where you accepted at least one completion.",
                       indent: true, get: { Settings.recordWithoutAccept }, set: { Settings.recordWithoutAccept = $0 }),
                row("Personalize word choice",
                    "Shows the model a few of your past sentences that resemble what you're typing. Higher values show more; too many may occasionally bias toward a less fitting word. Slightly slower, since the prompt changes each time.",
                    sliderRow, indent: true),
                existingRow,
                button("Recorded texts", "See, search and delete what has been recorded. Per-app deletion is in App Settings.",
                       "Show Typing History") { HistoryWindow.shared.show() },
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
                recorder("Trigger full completion", "Accepts the entire completion at once. Default: ⌥Tab.",
                         get: { Settings.keyAcceptAll }, set: { Settings.keyAcceptAll = $0 }),
                recorder("Complete only the next word",
                         "Each press inserts one more word, so you take exactly as much as you want and keep typing. Default: Tab.",
                         get: { Settings.keyAcceptWord }, set: { Settings.keyAcceptWord = $0 }),
                toggle("Include trailing space", "Accepting a single word also inserts the space after it.", indent: true,
                       get: { Settings.includeTrailingSpace }, set: { Settings.includeTrailingSpace = $0 }),
                popup("Include trailing punctuation",
                      "Whether accepting also inserts the comma or period after the words. Leaving it out helps when you keep writing, or don't want a chat message to end in a period. Punctuation left out stays in the suggestion, so another press inserts it.",
                      items: ["Never", "Only with full completion", "Always"],
                      selected: Settings.punctuationMode, set: { Settings.punctuationMode = $0 }),
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
        let modelPopup = styledPopup()
        modelPopup.addItem(withTitle: "Same as usual")
        currentStore().list { list in
            for m in list ?? [] { modelPopup.addItem(withTitle: m.name) }
            if !Settings.batteryModel.isEmpty {
                if modelPopup.item(withTitle: Settings.batteryModel) == nil { modelPopup.addItem(withTitle: Settings.batteryModel) }
                modelPopup.selectItem(withTitle: Settings.batteryModel)
            }
        }
        modelPopup.target = action { [weak modelPopup] _ in
            guard let p = modelPopup else { return }
            Settings.batteryModel = p.indexOfSelectedItem <= 0 ? "" : (p.titleOfSelectedItem ?? "")
        }
        modelPopup.action = #selector(Trampoline.fire(_:))
        let plugged = !Controller.onBattery
        return [
            section(nil, [
                row(plugged ? "You're plugged in" : "You're on battery power",
                    plugged ? "The settings below take effect automatically when the Mac switches to battery." : "The settings below are in effect now.", nil),
            ]),
            section("On Battery Power", [
                toggle("Only show completions on demand",
                       "LocalType stops suggesting on its own and waits for the force-activate shortcut (set it in Shortcuts), so you get suggestions only where you want them.",
                       get: { Settings.batteryOnDemand }, set: { Settings.batteryOnDemand = $0 }),
                row("Use a smaller model", "A lighter model uses less power and answers faster, with somewhat weaker suggestions.", modelPopup),
                toggle("Generate slightly shorter completions", "Shorter completions finish sooner, which saves power.",
                       get: { Settings.batteryShorter }, set: { Settings.batteryShorter = $0 }),
            ]),
            section("Power", [
                toggle("Pause on battery power", "Turns completions off whenever the Mac isn't plugged in.",
                       get: { Settings.pauseOnBattery }, set: { Settings.pauseOnBattery = $0 }),
                toggle("Pause in Low Power Mode", "Skip suggestions when macOS Low Power Mode is on.",
                       get: { Settings.pauseLowPower }, set: { Settings.pauseLowPower = $0 }),
            ]),
        ]
    }

    /// A list row: icon, title and subtitle on the left, controls on the right.
    private func listRow(icon: NSImage?, _ title: String, _ subtitle: String?, _ controls: [NSView]) -> NSView {
        let img = NSImageView(image: icon ?? NSImage())
        img.imageScaling = .scaleProportionallyUpOrDown
        img.widthAnchor.constraint(equalToConstant: 22).isActive = true
        img.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let t = NSTextField(labelWithString: title)
        var texts: [NSView] = [t]
        if let subtitle {
            let st = NSTextField(labelWithString: subtitle)
            st.font = .systemFont(ofSize: 11); st.textColor = .secondaryLabelColor
            st.lineBreakMode = .byTruncatingMiddle
            texts.append(st)
        }
        let col = NSStackView(views: texts); col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for c in controls { c.setContentHuggingPriority(.required, for: .horizontal) }
        let h = NSStackView(views: [img, col, spacer] + controls)
        h.alignment = .centerY; h.spacing = 10
        h.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        return h
    }

    private func onOffSwitch(_ on: Bool, _ set: @escaping (Bool) -> Void) -> NSSwitch {
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = on ? .on : .off
        sw.target = action { s in set((s as? NSSwitch)?.state == .on) }
        sw.action = #selector(Trampoline.fire(_:))
        return sw
    }

    /// "⋯" pull-down with named actions.
    private func moreMenu(_ items: [(String, () -> Void)]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.bezelStyle = .texturedRounded
        p.addItem(withTitle: "⋯")
        for (title, f) in items {
            let mi = NSMenuItem(title: title, action: #selector(Trampoline.fire(_:)), keyEquivalent: "")
            mi.target = action { _ in f() }
            p.menu?.addItem(mi)
        }
        return p
    }

    private func appInfo(_ bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return (bundleID, nil) }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var rules = Settings.appRules
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, rules[id] == nil else { continue }
            rules[id] = !Settings.enabledByDefault   // adding an app is usually to flip it from the default
        }
        Settings.appRules = rules
        reload()
    }

    private func addWebsite() {
        let a = NSAlert()
        a.messageText = "Add a website"
        a.informativeText = "Enter a domain such as mail.google.com or google.com. A domain also covers its subdomains, in any browser."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "example.com"
        a.accessoryView = field
        a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var d = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let u = URL(string: d.contains("://") ? d : "https://" + d), let host = u.host { d = host }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        guard d.contains("."), !d.contains(" ") else { return }
        var rules = Settings.domainRules
        rules[d] = rules[d] ?? !Settings.enabledByDefault
        Settings.domainRules = rules
        reload()
    }

    private func appSettings() -> [NSView] {
        let apps = Settings.appRules.map { (id: $0.key, on: $0.value, info: appInfo($0.key)) }
            .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
        var appRows: [NSView] = apps.map { app in
            let n = History.shared.count(app: app.id)
            var menu: [(String, () -> Void)] = [("Remove from list", {
                var r = Settings.appRules; r[app.id] = nil; Settings.appRules = r; self.reload()
            })]
            if n > 0 {
                menu.insert(("Delete typing history (\(n))…", {
                    let a = NSAlert()
                    a.messageText = "Delete the typing history recorded in \(app.info.name)?"
                    a.informativeText = "\(n) recorded texts will be removed. This can't be undone."
                    a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { History.shared.delete(app: app.id); self.reload() }
                }), at: 0)
            }
            return listRow(icon: app.info.icon, app.info.name, n > 0 ? "\(app.id) · \(n) texts recorded" : app.id, [
                onOffSwitch(app.on) { on in var r = Settings.appRules; r[app.id] = on; Settings.appRules = r },
                moreMenu(menu),
            ])
        }
        if appRows.isEmpty {
            appRows = [row("No apps yet", "Every app follows the default above. Add an app to give it its own setting, or use “Disable in …” in the menu-bar menu.", nil)]
        }
        let addAppBtn = NSButton(title: "Add App…", target: action { _ in self.addApp() }, action: #selector(Trampoline.fire(_:)))
        addAppBtn.bezelStyle = .rounded

        let sites = Settings.domainRules.sorted { $0.key < $1.key }
        var siteRows: [NSView] = sites.map { site in
            listRow(icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil), site.key, nil, [
                onOffSwitch(site.value) { on in var r = Settings.domainRules; r[site.key] = on; Settings.domainRules = r },
                moreMenu([("Remove from list", { var r = Settings.domainRules; r[site.key] = nil; Settings.domainRules = r; self.reload() })]),
            ])
        }
        if siteRows.isEmpty {
            siteRows = [row("No websites yet", "A website rule applies in every browser and wins over the browser's own app setting.", nil)]
        }
        let addSiteBtn = NSButton(title: "Add Website…", target: action { _ in self.addWebsite() }, action: #selector(Trampoline.fire(_:)))
        addSiteBtn.bezelStyle = .rounded

        return [
            section(nil, [
                toggle("Enable completions by default", "Apps and websites without their own setting below follow this.",
                       get: { Settings.enabledByDefault }, set: { Settings.enabledByDefault = $0 }),
            ]),
            section("Apps", appRows),
            NSStackView(views: [NSView(), addAppBtn]),
            section("Websites", siteRows),
            NSStackView(views: [NSView(), addSiteBtn]),
        ]
    }

    private var statsSpan = 30
    private var statsGrouping = Stats.Grouping.day
    private var statsMetric = Stats.Metric.words

    /// A big number with a caption under it.
    private func tile(_ value: String, _ caption: String) -> NSView {
        let v = NSTextField(labelWithString: value)
        let base = NSFont.systemFont(ofSize: 26, weight: .semibold)
        v.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 26) } ?? base
        let c = NSTextField(labelWithString: caption)
        c.font = .systemFont(ofSize: 11); c.textColor = .secondaryLabelColor
        let st = NSStackView(views: [v, c]); st.orientation = .vertical; st.alignment = .leading; st.spacing = 2
        return st
    }

    private func statistics() -> [NSView] {
        let today = Stats.shared.today
        let tiles = NSStackView(views: [tile("\(today.completions)", "Completions"), tile("\(today.words)", "Words"),
                                        tile("\(today.chars)", "Characters")])
        tiles.distribution = .fillEqually
        tiles.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let spans = [(7, "Last 7 Days"), (30, "Last 30 Days"), (90, "Last 90 Days"), (365, "Last 12 Months")]
        let chart = BarChartView()
        chart.grouping = statsGrouping
        chart.data = Stats.shared.series(span: statsSpan, grouping: statsGrouping, metric: statsMetric)
        let sum = Stats.shared.summary(span: statsSpan, metric: statsMetric)
        func picker(_ items: [String], _ sel: Int, _ f: @escaping (Int) -> Void) -> NSPopUpButton {
            let p = self.styledPopup()
            p.addItems(withTitles: items); p.selectItem(at: sel)
            p.target = action { s in f((s as? NSPopUpButton)?.indexOfSelectedItem ?? 0); self.reload() }
            p.action = #selector(Trampoline.fire(_:))
            return p
        }
        let pickers = NSStackView(views: [
            picker(spans.map(\.1), spans.firstIndex { $0.0 == statsSpan } ?? 1) { self.statsSpan = spans[$0].0 },
            picker(Stats.Grouping.allCases.map(\.title), statsGrouping.rawValue) { self.statsGrouping = Stats.Grouping(rawValue: $0)! },
            picker(Stats.Metric.allCases.map(\.title), statsMetric.rawValue) { self.statsMetric = Stats.Metric(rawValue: $0)! },
        ])
        pickers.spacing = 8
        pickers.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 0, right: 14)
        let chartBox = NSStackView(views: [chart])
        chartBox.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        chart.widthAnchor.constraint(equalTo: chartBox.widthAnchor, constant: -28).isActive = true
        let summary = NSStackView(views: [tile("\(sum.total)", "Total \(statsMetric.title.lowercased())"),
                                          tile("\(sum.perActiveDay)", "Daily average (active days)"),
                                          tile(Stats.timeSaved(words: sum.words), "Estimated time saved")])
        summary.distribution = .fillEqually
        summary.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 12, right: 14)

        let rate = Settings.shown > 0 ? String(format: "%.0f%%", Double(Settings.accepted) / Double(Settings.shown) * 100) : "–"
        return [
            section("Today", [tiles]),
            section("Completion Statistics", [pickers, chartBox, summary]),
            section("All Time (stored only on this Mac)", [
                row("Suggestions shown", nil, NSTextField(labelWithString: "\(Settings.shown)")),
                row("Suggestions accepted", nil, NSTextField(labelWithString: "\(Settings.accepted)")),
                row("Acceptance rate", nil, NSTextField(labelWithString: rate)),
                row("Words inserted", Settings.wordsAccepted > 0 ? Stats.timeSaved(words: Settings.wordsAccepted) + " of typing saved" : nil,
                    NSTextField(labelWithString: "\(Settings.wordsAccepted)")),
                row("Typo fixes applied", nil, NSTextField(labelWithString: "\(Settings.fixesApplied)")),
                row("Emoji inserted", nil, NSTextField(labelWithString: "\(Settings.emojiInserted)")),
                button("Reset statistics", "Clears all numbers on this page, including the daily history.", "Reset…") {
                    let a = NSAlert()
                    a.messageText = "Reset all statistics?"
                    a.informativeText = "This can't be undone."
                    a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { Settings.resetStats(); Stats.shared.reset(); self.reload() }
                },
            ]),
        ]
    }

    func windowWillClose(_ notification: Notification) { retained = []; textBindings = [:] }
}
