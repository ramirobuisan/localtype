import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let perApp = NSMenuItem(title: "", action: #selector(toggleFrontmostApp), keyEquivalent: "")
    private let models = NSMenuItem(title: "Models…", action: #selector(openModels), keyEquivalent: "m")
    private let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private var permissionTimer: Timer?
    private var frontmostID: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "Cotypist")

        let m = NSMenu()
        m.delegate = self
        m.addItem(statusLine)
        m.addItem(.separator())
        for i in [toggle, perApp, models, settings] { i.target = self; m.addItem(i) }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = m
        refresh()

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            if !Settings.enabled { Controller.shared.dismiss() }
            self?.refresh()
        }
        ModelsWindow.shared.onChange = { [weak self] in self?.checkModelStatusOnly() }
        Controller.shared.onStatus = { [weak self] s in self?.statusLine.title = s }
        startWhenTrusted()
    }

    func applicationWillTerminate(_ n: Notification) { LlamaEngine.shared.shutdown() }

    private func startWhenTrusted() {
        if AX.trusted(prompt: true), Controller.shared.start() {
            checkModel()
            return
        }
        statusLine.title = "Grant Accessibility access…"
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if AX.trusted(prompt: false), Controller.shared.start() {
                t.invalidate()
                self?.checkModel()
            }
        }
    }

    private func refresh() {
        toggle.state = Settings.enabled ? .on : .off
        item.button?.appearsDisabled = !Settings.enabled
        item.isVisible = Settings.showMenuBarIcon
    }

    // Frontmost app is unchanged while our menu is open (we're an accessory app).
    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = NSWorkspace.shared.frontmostApplication
        frontmostID = app?.bundleIdentifier
        if let id = frontmostID, let name = app?.localizedName {
            perApp.isHidden = false
            perApp.title = Settings.allowed(bundleID: id) ? "Disable in \(name)" : "Enable in \(name)"
        } else {
            perApp.isHidden = true
        }
    }

    @objc private func toggleEnabled() { Settings.enabled.toggle() }

    @objc private func toggleFrontmostApp() {
        guard let id = frontmostID else { return }
        var list = Settings.enabledByDefault ? Settings.disabledApps : Settings.enabledApps
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        if Settings.enabledByDefault { Settings.disabledApps = list } else { Settings.enabledApps = list }
        Controller.shared.dismiss()
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }

    private func checkModelStatusOnly() {
        let store = currentStore()
        store.list { [weak self] list in
            let have = list?.contains { store.isActive($0.name) } ?? false
            let name = store.activeName
            self?.statusLine.title = have ? "Ready · \(name)" : "No model selected — open Models…"
        }
    }

    @objc private func openModels() { ModelsWindow.shared.show() }

    /// Reports model readiness; warms up the embedded model or starts Ollama as needed.
    private func checkModel() {
        if Settings.backend == "embedded" {
            if GGUFStore.activePath == nil, let first = GGUFStore.shared.list().first {
                Settings.embeddedModel = first.name   // auto-select an installed model
            }
            if let p = GGUFStore.activePath {
                LlamaEngine.shared.preload(path: p)
            } else if GGUFStore.shared.list().isEmpty {
                ModelsWindow.shared.show()
            }
            checkModelStatusOnly()
            return
        }
        ModelManager.shared.ensureServer { [weak self] up in
            guard let self else { return }
            guard up else {
                self.statusLine.title = ModelManager.ollamaBinary == nil ? "Ollama not installed" : "Ollama unreachable"
                return
            }
            ModelManager.shared.list { list in
                if list?.isEmpty == true { ModelsWindow.shared.show() }
                self.checkModelStatusOnly()
            }
        }
    }

    @objc private func openSettings() { SettingsWindow.shared.show() }
}
