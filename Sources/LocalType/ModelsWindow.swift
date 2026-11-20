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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "LocalType Models"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        source.target = self; source.action = #selector(sourceChanged)

        for (id, title, width) in [("name", "Model", 270.0), ("size", "Size", 80.0), ("active", "Active", 60.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.heightAnchor.constraint(equalToConstant: 160).isActive = true

        useBtn.target = self; useBtn.action = #selector(useSelected)
        delBtn.target = self; delBtn.action = #selector(deleteSelected)
        importBtn.target = self; importBtn.action = #selector(importFile)
        let rowBtns = NSStackView(views: [useBtn, delBtn, importBtn])
        rowBtns.spacing = 8

        picker.isEditable = true
        picker.widthAnchor.constraint(equalToConstant: 360).isActive = true
        download.target = self; download.action = #selector(startDownload)
        cancel.target = self; cancel.action = #selector(cancelDownload)
        cancel.isHidden = true
        let dl = NSStackView(views: [picker, download, cancel])
        dl.spacing = 8

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.isHidden = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        func header(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .boldSystemFont(ofSize: 12); return l
        }
        let dlHeader = header("Download a model")
        downloadViews = [dlHeader, dl]
        let stack = NSStackView(views: [source, header("Installed"), sv, rowBtns, dlHeader, dl, bar, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cv = NSView()
        cv.addSubview(stack)
        w.contentView = cv
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            sv.widthAnchor.constraint(equalToConstant: 500),
            bar.widthAnchor.constraint(equalToConstant: 500),
        ])
        w.setContentSize(stack.fittingSize)
        window = w
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
        let text: String
        switch col?.identifier.rawValue {
        case "size": text = ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file)
        case "active": text = store.isActive(m.name) ? "✓" : ""
        default: text = m.name
        }
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byTruncatingMiddle
        return l
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
