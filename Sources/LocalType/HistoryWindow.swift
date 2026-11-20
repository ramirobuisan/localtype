import AppKit

/// Shows the locally recorded writing (Personalization → Show Typing History): search, delete selected, delete all.
final class HistoryWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = HistoryWindow()

    private var window: NSWindow?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [History.Entry] = []
    private var appNames: [String: String] = [:]
    private let dateFormat: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()

    func show() {
        if window == nil { build() }
        reloadRows()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Typing History"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 360)
        w.delegate = self
        w.center()

        // Header: icon, title and where the data lives.
        let tile = NSImageView(image: iconTile("clock.arrow.circlepath", .systemPurple, size: 38))
        tile.widthAnchor.constraint(equalToConstant: 38).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let title = NSTextField(labelWithString: "Typing History")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let note = NSTextField(wrappingLabelWithString:
            "Sentences you wrote, used to make suggestions sound like you. Encrypted and stored only on this Mac.")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, note]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [tile, titles]); header.alignment = .centerY; header.spacing = 12

        for (id, title, width) in [("date", "Date", 140.0), ("app", "App", 130.0), ("text", "Text", 440.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width
            if id == "text" { c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .plain
        table.rowHeight = 26
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        let card = CardView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: card.topAnchor, constant: 4), sv.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            sv.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4), sv.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
        ])
        // Shown over the empty list: why there's nothing yet.
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])

        search.placeholderString = "Search text or app"
        search.delegate = self
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 12)
        let delSel = NSButton(title: "Delete Selected", target: self, action: #selector(deleteSelected))
        let delAll = NSButton(title: "Delete All…", target: self, action: #selector(deleteAll))
        for b in [delSel, delAll] { b.bezelStyle = .push }
        let top = NSStackView(views: [search, NSView(), countLabel])
        top.alignment = .centerY
        let bottom = NSStackView(views: [delAll, NSView(), delSel])
        let views: [NSView] = [header, top, card, bottom]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.defaultLow, for: .vertical)
        let cv = NSView()
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor), stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            search.widthAnchor.constraint(equalToConstant: 260),
        ])
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        w.contentView = cv
        window = w
    }

    private func appName(_ id: String?) -> String {
        guard let id else { return "–" }
        if let n = appNames[id] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        appNames[id] = n
        return n
    }

    private func reloadRows() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = History.shared.entries.reversed().filter { q.isEmpty || $0.text.lowercased().contains(q) || appName($0.app).lowercased().contains(q) }
        table.reloadData()
        countLabel.stringValue = q.isEmpty ? "\(rows.count) texts" : "\(rows.count) of \(History.shared.count) texts"
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = History.shared.count == 0
            ? (Settings.recordWriting ? "Nothing recorded yet. Finished sentences you write will appear here."
                                      : "Nothing recorded. Turn on “Record your writing” in Settings → Personalization to let suggestions learn your phrasing.")
            : "No texts match your search."
    }

    func controlTextDidChange(_ obj: Notification) { reloadRows() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let e = rows[row]
        let text: String
        switch col?.identifier.rawValue {
        case "date": text = dateFormat.string(from: e.date)
        case "app": text = appName(e.app)
        default: text = e.text
        }
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byTruncatingTail
        l.toolTip = col?.identifier.rawValue == "text" ? e.text : nil
        return l
    }

    @objc private func deleteSelected() {
        let sel = table.selectedRowIndexes.map { rows[$0] }
        guard !sel.isEmpty else { return }
        for e in sel { History.shared.delete(e) }
        reloadRows()
    }

    @objc private func deleteAll() {
        let a = NSAlert()
        a.messageText = "Delete all recorded writing?"
        a.informativeText = "This removes the local history used for personalization. It can't be undone."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { History.shared.deleteAll(); reloadRows() }
    }
}
