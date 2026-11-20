import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let perApp = NSMenuItem(title: "", action: #selector(toggleFrontmostApp), keyEquivalent: "")
    private let perSite = NSMenuItem(title: "", action: #selector(toggleFrontmostSite), keyEquivalent: "")
    private var frontmostDomain: String?
    private let models = NSMenuItem(title: "Models…", action: #selector(openModels), keyEquivalent: "m")
    private let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private let setup = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: "")
    private let update = NSMenuItem(title: "", action: #selector(openUpdate), keyEquivalent: "")
    private let today = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var permissionTimer: Timer?
    private var frontmostID: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "LocalType")

        let m = NSMenu()
        m.delegate = self
        m.addItem(statusLine)
        today.isEnabled = false
        m.addItem(today)
        m.addItem(.separator())
        for i in [toggle, perApp, perSite, models, settings, setup] { i.target = self; m.addItem(i) }
        let symbols: [(NSMenuItem, String)] = [(toggle, "power"), (perApp, "app.dashed"), (perSite, "globe"), (models, "cpu"),
                                               (settings, "gearshape"), (setup, "checkmark.seal"), (update, "arrow.down.circle")]
        for (i, sym) in symbols { i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil) }
        update.target = self
        update.isHidden = true
        m.addItem(update)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = m
        refresh()

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            if !Settings.enabled { Controller.shared.dismiss() }
            self?.refresh()
            AccessoryButton.shared.update()
        }
        AccessoryButton.shared.openMenu = { [weak self] point in
            guard let menu = self?.item.menu else { return }
            menu.popUp(positioning: nil, at: point, in: nil)
        }
        AccessoryButton.shared.update()
        ModelsWindow.shared.onChange = { [weak self] in self?.checkModelStatusOnly() }
        // A suggestion failed (problem) or works again (nil, after a failure).
        Controller.shared.onStatus = { [weak self] problem in
            guard let self else { return }
            if let problem { self.setStatus(problem, ok: false, fix: ("Reconnect", #selector(self.reconnect))) } else { self.checkModelStatusOnly() }
        }
        let firstRun = !Settings.onboardingDone || CommandLine.arguments.contains("--setup")
        Sync.update()
        // After sleep the model may have been unloaded: warm it up before the first suggestion.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { LLM.warmUp() }
        }
        startWhenTrusted(prompt: !firstRun)
        ScreenContext.shared.prewarm()
        Updates.checkInBackgroundIfDue { [weak self] in self?.refreshUpdateItem() }
        if firstRun { OnboardingWindow.shared.show() }
        // Development: --open-menu <seconds> opens the menu-bar menu after a delay, for screenshots.
        if let i = CommandLine.arguments.firstIndex(of: "--open-menu"), i + 1 < CommandLine.arguments.count,
           let delay = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.item.button?.performClick(nil) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            let args = CommandLine.arguments
            SettingsWindow.shared.show(page: i + 1 < args.count ? args[i + 1] : "General")
        }
    }

    func applicationWillTerminate(_ n: Notification) { LlamaEngine.shared.shutdown() }

    private func startWhenTrusted(prompt: Bool) {
        if AX.trusted(prompt: prompt), Controller.shared.start() {
            checkModel()
            return
        }
        setStatus("Needs Accessibility access", ok: false, fix: ("Open Setup…", #selector(openSetup)))
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
        let words = Stats.shared.today.words
        today.isHidden = words == 0
        today.attributedTitle = NSAttributedString(string: "Today: \(words) word\(words == 1 ? "" : "s") typed for you",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)])
        let app = NSWorkspace.shared.frontmostApplication
        frontmostID = app?.bundleIdentifier
        if let id = frontmostID, let name = app?.localizedName {
            perApp.isHidden = false
            perApp.title = Settings.allowed(bundleID: id) ? "Disable in \(name)" : "Enable in \(name)"
        } else {
            perApp.isHidden = true
        }
        // Website of the page being typed in, if the frontmost app shows one.
        frontmostDomain = app.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil
                                        : AX.focusedElement(ofApp: $0.processIdentifier) }.flatMap(AX.webDomain(of:))
        if let domain = frontmostDomain {
            let site = Settings.domainRule(for: domain)?.domain ?? domain
            perSite.isHidden = false
            perSite.title = Settings.allowed(bundleID: frontmostID, domain: domain) ? "Disable on \(site)" : "Enable on \(site)"
        } else {
            perSite.isHidden = true
        }
    }

    @objc private func toggleFrontmostSite() {
        guard let domain = frontmostDomain else { return }
        let site = Settings.domainRule(for: domain)?.domain ?? domain
        var rules = Settings.domainRules
        rules[site] = !Settings.allowed(bundleID: frontmostID, domain: domain)
        Settings.domainRules = rules
        Controller.shared.dismiss()
    }

    @objc private func toggleEnabled() { Settings.enabled.toggle() }

    @objc private func toggleFrontmostApp() {
        guard let id = frontmostID else { return }
        var rules = Settings.appRules
        rules[id] = !Settings.allowed(bundleID: id)
        Settings.appRules = rules
        Controller.shared.dismiss()
    }

    /// localtype://settings/<page>, localtype://setup, localtype://models, localtype://history, localtype://toggle
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "localtype" {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch url.host?.lowercased() {
            case "setup": OnboardingWindow.shared.show()
            case "models": ModelsWindow.shared.show()
            case "history": HistoryWindow.shared.show()
            case "toggle": Settings.enabled.toggle()
            default: SettingsWindow.shared.show(page: path.isEmpty ? "General" : path.removingPercentEncoding ?? path)
            }
        }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show(page: SettingsWindow.lastPage)
        return true
    }

    private func checkModelStatusOnly() {
        let store = currentStore()
        store.list { [weak self] list in
            let have = list?.contains { store.isActive($0.name) } ?? false
            let name = store.activeName
            if have { self?.setStatus("Ready · \(name.split(separator: "/").last.map(String.init) ?? name)", ok: true) }
            else { self?.setStatus("No model selected", ok: false, fix: ("Choose…", #selector(AppDelegate.openModels))) }
        }
    }

    @objc private func openModels() { ModelsWindow.shared.show() }

    /// Reports model readiness; warms up the embedded model or starts Ollama as needed.
    private func checkModel() {
        if Settings.backend == "mlxserve" {
            setStatus("Connecting to MLX-Serve…", ok: nil)
            MLXServeStore.shared.prepare { [weak self] problem in
                if let problem {
                    // First sentence only: the button replaces "Open it and try again".
                    let short = problem.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? problem
                    self?.setStatus(short, ok: false, fix: ("Try Again", #selector(AppDelegate.reconnect)))
                    return
                }
                MLXServeStore.shared.autoSelect { self?.checkModelStatusOnly(); LLM.warmUp() }
            }
            return
        }
        if Settings.backend == "embedded" {
            if GGUFStore.activePath == nil, let first = GGUFStore.shared.list().first {
                Settings.embeddedModel = first.name   // auto-select an installed model
            }
            if let p = GGUFStore.activePath {
                LlamaEngine.shared.preload(path: p)
            } else if GGUFStore.shared.list().isEmpty, Settings.onboardingDone {
                ModelsWindow.shared.show()
            }
            checkModelStatusOnly()
            return
        }
        ModelManager.shared.ensureServer { [weak self] up in
            guard let self else { return }
            guard up else {
                if ModelManager.ollamaBinary == nil { self.setStatus("Ollama not installed", ok: false) }
                else { self.setStatus("Ollama unreachable", ok: false, fix: ("Try Again", #selector(self.reconnect))) }
                return
            }
            ModelManager.shared.list { list in
                if list?.isEmpty == true, Settings.onboardingDone { ModelsWindow.shared.show() }
                self.checkModelStatusOnly()
            }
        }
    }

    @objc private func openSettings() { SettingsWindow.shared.show(page: SettingsWindow.lastPage) }
    @objc private func openSetup() { OnboardingWindow.shared.show() }

    /// Status line at the top of the menu: a colored dot (green ready, orange needs attention, gray working) and text.
    /// When something needs fixing, `fix` is what clicking the line does, named after the text in the accent color.
    private func setStatus(_ text: String, ok: Bool?, fix: (title: String, action: Selector)? = nil) {
        let color: NSColor = ok == true ? .systemGreen : ok == false ? .systemOrange : .systemGray
        let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color, .font: NSFont.menuFont(ofSize: 11)])
        s.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                               .font: NSFont.menuFont(ofSize: 0)]))
        if let fix {
            s.append(NSAttributedString(string: " — \(fix.title)", attributes: [.foregroundColor: NSColor.controlAccentColor,
                                                                                .font: NSFont.menuFont(ofSize: 0)]))
        }
        statusLine.attributedTitle = s
        statusLine.target = fix == nil ? nil : self
        statusLine.action = fix?.action
    }

    /// Reconnects to the engine: reopens MLX-Serve or starts Ollama if needed, then warms the model up.
    @objc private func reconnect() { checkModel() }

    private func refreshUpdateItem() {
        update.isHidden = Updates.available == nil
        if let r = Updates.available { update.title = "LocalType \(r.version) Available…" }
    }

    @objc private func openUpdate() { if let r = Updates.available { UpdateWindow.shared.show(r) } }
}
