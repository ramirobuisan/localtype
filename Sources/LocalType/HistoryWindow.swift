import AppKit

/// Shows the locally recorded writing (Personalization → Show Typing History): search, delete selected, delete all.
final class HistoryWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = HistoryWindow()

    private var window: NSWindow?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Typing History"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 300)
        w.delegate = self
        w.center()

        for (id, title, width) in [("date", "Date", 130.0), ("app", "App", 130.0), ("text", "Text", 460.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width
            if id == "text" { c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder

        search.placeholderString = "Search"
        search.delegate = self
        let delSel = NSButton(title: "Delete Selected", target: self, action: #selector(deleteSelected))
        let delAll = NSButton(title: "Delete All…", target: self, action: #selector(deleteAll))
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        let note = NSTextField(wrappingLabelWithString:
            "Stored only on this Mac (~/Library/Application Support/LocalType/history.json, readable only by you). Used to make suggestions sound like you.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let top = NSStackView(views: [search, NSView(), countLabel])
        let bottom = NSStackView(views: [delSel, delAll, NSView()])
        let stack = NSStackView(views: [top, sv, bottom, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cv = NSView()
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor), stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            search.widthAnchor.constraint(equalToConstant: 240),
        ])
        for v in [top, sv, bottom, note] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
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
