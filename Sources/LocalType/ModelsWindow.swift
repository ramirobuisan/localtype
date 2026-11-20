import AppKit

final class ModelsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ModelsWindow()

    private var window: NSWindow?
    private static let backends = ["mlxserve", "embedded", "ollama"]
    private let source = NSSegmentedControl(labels: ["MLX-Serve", "Built-in engine", "Ollama"], trackingMode: .selectOne, target: nil, action: nil)
    private var downloadViews: [NSView] = []
    private let table = NSTableView()
    private let picker = NSComboBox()
    private let download = NSButton(title: "Download", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let useBtn = NSButton(title: "Use selected", target: nil, action: nil)
    private let delBtn = NSButton(title: "Delete selected", target: nil, action: nil)
    private let importBtn = NSButton(title: "Import .gguf…", target: nil, action: nil)
    private let bar = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private var models: [InstalledModel] = []
    private var store: ModelStore { currentStore() }

    /// Called whenever the model list or active model may have changed.
    var onChange: (() -> Void)?

    func show() {
        if window == nil { build() }
        source.selectedSegment = ModelsWindow.backends.firstIndex(of: Settings.backend) ?? 0
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        reloadSource()
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "LocalType Models"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        // Header
        let tile = NSImageView(image: iconTile("cpu", .systemPurple, size: 38))
        tile.widthAnchor.constraint(equalToConstant: 38).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let title = NSTextField(labelWithString: "Models")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let blurb = NSTextField(wrappingLabelWithString: "Where LocalType's suggestions come from. Smaller models answer faster.")
        blurb.font = .systemFont(ofSize: 12); blurb.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, blurb]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        let header = NSStackView(views: [tile, titles]); header.alignment = .centerY; header.spacing = 12

        source.target = self; source.action = #selector(sourceChanged)
        source.segmentDistribution = .fillEqually
        source.controlSize = .large

        // Installed models: a borderless table inside a card.
        for (id, title, width) in [("active", "", 26.0), ("name", "Model", 380.0), ("size", "Size", 80.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width
            if id == "active" { c.minWidth = 26; c.maxWidth = 26 }
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = 28
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let installed = Self.card(sv, inset: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))

        useBtn.target = self; useBtn.action = #selector(useSelected)
        delBtn.target = self; delBtn.action = #selector(deleteSelected)
        importBtn.target = self; importBtn.action = #selector(importFile)
        useBtn.keyEquivalent = "\r"
        for b in [useBtn, delBtn, importBtn] { b.bezelStyle = .push }
        let rowBtns = NSStackView(views: [importBtn, NSView(), delBtn, useBtn])
        rowBtns.spacing = 8

        // Download
        picker.isEditable = true
        picker.font = .systemFont(ofSize: 13)
        download.target = self; download.action = #selector(startDownload)
        download.bezelStyle = .push
        cancel.target = self; cancel.action = #selector(cancelDownload)
        cancel.bezelStyle = .push
        cancel.isHidden = true
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let dl = NSStackView(views: [picker, download, cancel])
        dl.spacing = 8
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.isHidden = true
        let dlStack = NSStackView(views: [dl, bar])
        dlStack.orientation = .vertical; dlStack.alignment = .leading; dlStack.spacing = 8
        dl.widthAnchor.constraint(equalTo: dlStack.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: dlStack.widthAnchor).isActive = true
        let dlCard = Self.card(dlStack, inset: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        func heading(_ s: String) -> NSView {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 13, weight: .semibold)
            let w = NSStackView(views: [l]); w.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0); return w
        }
        let dlHeader = heading("Download a model")
        downloadViews = [dlHeader, dlCard]
        let views: [NSView] = [header, source, heading("Installed"), installed, rowBtns, dlHeader, dlCard, status]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: header)
        stack.setCustomSpacing(18, after: source)
        stack.setCustomSpacing(18, after: rowBtns)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true }
        let cv = NSView()
        cv.addSubview(stack)
        w.contentView = cv
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            cv.widthAnchor.constraint(equalToConstant: 600),
        ])
        window = w
    }

    /// Content inside a System Settings-style card.
    private static func card(_ content: NSView, inset: NSEdgeInsets) -> NSView {
        let c = CardView()
        content.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: c.topAnchor, constant: inset.top),
            content.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -inset.bottom),
            content.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -inset.right),
        ])
        return c
    }

    @objc private func sourceChanged() {
        Settings.backend = ModelsWindow.backends[max(0, source.selectedSegment)]
        if Settings.backend != "embedded" { LlamaEngine.shared.unload() }
        reloadSource()
    }

    private func reloadSource() {
        picker.removeAllItems()
        picker.addItems(withObjectValues: store.catalog.map { "\($0.id)   \($0.note)" })
        picker.stringValue = ""
        picker.placeholderString = store.placeholder
        importBtn.isHidden = !store.canImport
        delBtn.isHidden = !store.canDelete
        for v in downloadViews { v.isHidden = !store.canDownload }
        window?.setContentSize((window?.contentView?.subviews.first?.fittingSize) ?? .zero)
        refresh()
    }

    // MARK: Data

    func refresh() {
        status.stringValue = "Loading…"
        store.prepare { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.status.stringValue = problem
                self.models = []; self.table.reloadData(); return
            }
            self.store.list { list in
                self.models = list ?? []
                self.table.reloadData()
                if !self.store.isBusy { self.status.stringValue = self.models.isEmpty ? "No models installed yet" : "" }
                self.onChange?()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let m = models[row]
        switch col?.identifier.rawValue {
        case "active":
            guard store.isActive(m.name) else { return NSView() }
            let img = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Active") ?? NSImage())
            img.contentTintColor = .systemGreen
            return img
        case "size":
            let l = NSTextField(labelWithString: m.size > 0 ? ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file) : "")
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            return l
        default:
            let l = NSTextField(labelWithString: m.name)
            l.font = .systemFont(ofSize: 13, weight: store.isActive(m.name) ? .semibold : .regular)
            l.lineBreakMode = .byTruncatingMiddle
            return l
        }
    }

    private var selected: InstalledModel? {
        table.selectedRow >= 0 && table.selectedRow < models.count ? models[table.selectedRow] : nil
    }

    // MARK: Actions

    @objc private func useSelected() {
        guard let m = selected else { return }
        store.activeName = m.name
        table.reloadData()
        onChange?()
    }

    @objc private func deleteSelected() {
        guard let m = selected else { return }
        let a = NSAlert()
        a.messageText = "Delete \(m.name)?"
        a.informativeText = "This removes the model files from disk. You can download it again later."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.delete(m.name) { [weak self] ok in
            self?.status.stringValue = ok ? "Deleted \(m.name)" : "Couldn't delete \(m.name)"
            self?.refresh()
        }
    }

    @objc private func importFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.message = "Choose a .gguf model file"
        guard p.runModal() == .OK, let url = p.url else { return }
        guard url.pathExtension.lowercased() == "gguf" else { status.stringValue = "That isn't a .gguf file"; return }
        status.stringValue = "Copying \(url.lastPathComponent)…"
        DispatchQueue.global().async {
            let err = GGUFStore.shared.importFile(url)
            DispatchQueue.main.async {
                if let err { self.status.stringValue = err; return }
                if self.store.activeName.isEmpty { self.store.activeName = url.lastPathComponent }
                self.refresh()
            }
        }
    }

    @objc private func startDownload() {
        // Combo items look like "name   note"; take the first token.
        let raw = picker.stringValue.trimmingCharacters(in: .whitespaces)
        guard let name = raw.split(separator: " ").first.map(String.init), !name.isEmpty else { return }
        download.isEnabled = false; cancel.isHidden = false
        bar.isHidden = false; bar.doubleValue = 0
        status.stringValue = "Starting…"
        let store = self.store
        store.prepare { [weak self] problem in
            guard let self else { return }
            if let problem { self.endDownload(problem); return }
            store.download(name, progress: { st, frac in
                if let f = frac { self.bar.doubleValue = f }
                self.status.stringValue = st
            }, done: { err in
                if let err { self.endDownload(err); return }
                let installed = name.hasPrefix("http") ? (URL(string: name)?.lastPathComponent ?? name) : name
                self.endDownload("Downloaded \(installed)")
                if store.activeName.isEmpty || !self.models.contains(where: { store.isActive($0.name) }) {
                    store.activeName = installed.contains(":") || installed.hasSuffix(".gguf") ? installed : installed + ":latest"
                }
                self.refresh()
            })
        }
    }

    private func endDownload(_ message: String) {
        download.isEnabled = true; cancel.isHidden = true; bar.isHidden = true
        status.stringValue = message
    }

    @objc private func cancelDownload() { store.cancelDownload() }
}
