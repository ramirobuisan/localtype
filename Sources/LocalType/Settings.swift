import Foundation
import ServiceManagement

extension Notification.Name {
    static let settingsChanged = Notification.Name("LocalTypeSettingsChanged")
}

enum Settings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled"); notify() }
    }
    static var model: String {
        get { d.string(forKey: "model") ?? "qwen2.5:3b" }
        set { d.set(newValue, forKey: "model"); notify() }
    }
    /// "embedded" = built-in llama.cpp engine, "ollama" = external Ollama server.
    static var backend: String {
        get { d.string(forKey: "backend") ?? "embedded" }
        set { d.set(newValue, forKey: "backend"); notify() }
    }
    /// GGUF file name (inside ~/Library/Application Support/LocalType/Models) for the embedded engine.
    static var embeddedModel: String {
        get { d.string(forKey: "embeddedModel") ?? "" }
        set { d.set(newValue, forKey: "embeddedModel"); notify() }
    }
    static var endpoint: String {
        get { d.string(forKey: "endpoint") ?? "http://localhost:11434" }
        set { d.set(newValue, forKey: "endpoint") }
    }
    static var maxTokens: Int {
        get { d.object(forKey: "maxTokens") as? Int ?? 12 }
        set { d.set(newValue, forKey: "maxTokens") }
    }
    static var debounceMs: Int {
        get { d.object(forKey: "debounceMs") as? Int ?? 250 }
        set { d.set(newValue, forKey: "debounceMs") }
    }
    /// Free-form writing-style / language hint prepended to the prompt.
    static var instructions: String {
        get { d.string(forKey: "instructions") ?? "" }
        set { d.set(newValue, forKey: "instructions") }
    }
    /// Bundle IDs where suggestions are turned off.
    static var disabledApps: [String] {
        get { d.stringArray(forKey: "disabledApps") ?? [] }
        set { d.set(newValue, forKey: "disabledApps"); notify() }
    }
    static var showMenuBarIcon: Bool {
        get { d.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMenuBarIcon"); notify() }
    }
    /// When false, completions are off everywhere except apps in `enabledApps`.
    static var enabledByDefault: Bool {
        get { d.object(forKey: "enabledByDefault") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabledByDefault"); notify() }
    }
    static var enabledApps: [String] {
        get { d.stringArray(forKey: "enabledApps") ?? [] }
        set { d.set(newValue, forKey: "enabledApps"); notify() }
    }
    static func allowed(bundleID: String?) -> Bool {
        guard let id = bundleID else { return enabledByDefault }
        return enabledByDefault ? !disabledApps.contains(id) : enabledApps.contains(id)
    }
    /// Suggest even when there is text after the caret on the same line.
    static var completeInside: Bool {
        get { d.object(forKey: "completeInside") as? Bool ?? false }
        set { d.set(newValue, forKey: "completeInside") }
    }
    static var typoGuard: Bool {
        get { d.object(forKey: "typoGuard") as? Bool ?? true }
        set { d.set(newValue, forKey: "typoGuard") }
    }
    static var suggestFixes: Bool {
        get { d.object(forKey: "suggestFixes") as? Bool ?? true }
        set { d.set(newValue, forKey: "suggestFixes") }
    }
    static var pauseOnBattery: Bool {
        get { d.object(forKey: "pauseOnBattery") as? Bool ?? false }
        set { d.set(newValue, forKey: "pauseOnBattery") }
    }
    static var pauseLowPower: Bool {
        get { d.object(forKey: "pauseLowPower") as? Bool ?? true }
        set { d.set(newValue, forKey: "pauseLowPower") }
    }
    // Statistics (local only)
    static var shown: Int { get { d.integer(forKey: "statShown") } set { d.set(newValue, forKey: "statShown") } }
    static var accepted: Int { get { d.integer(forKey: "statAccepted") } set { d.set(newValue, forKey: "statAccepted") } }
    static var wordsAccepted: Int { get { d.integer(forKey: "statWords") } set { d.set(newValue, forKey: "statWords") } }
    static var fixesApplied: Int { get { d.integer(forKey: "statFixes") } set { d.set(newValue, forKey: "statFixes") } }
    static var emojiInserted: Int { get { d.integer(forKey: "statEmoji") } set { d.set(newValue, forKey: "statEmoji") } }
    static func resetStats() { shown = 0; accepted = 0; wordsAccepted = 0; fixesApplied = 0; emojiInserted = 0 }

    // Context / personalization
    /// Read the window you're typing in (screen capture + on-device text recognition) for context.
    static var useScreen: Bool {
        get { d.bool(forKey: "useScreen") }
        set { d.set(newValue, forKey: "useScreen") }
    }
    /// ":name" suggests an emoji.
    static var emojiCompletion: Bool {
        get { d.object(forKey: "emojiCompletion") as? Bool ?? true }
        set { d.set(newValue, forKey: "emojiCompletion") }
    }
    /// How often each emoji was inserted; ranks frequent ones first.
    static var emojiUsage: [String: Int] {
        get { d.dictionary(forKey: "emojiUsage") as? [String: Int] ?? [:] }
        set { d.set(newValue, forKey: "emojiUsage") }
    }
    static var onboardingDone: Bool {
        get { d.bool(forKey: "onboardingDone") }
        set { d.set(newValue, forKey: "onboardingDone") }
    }
    static var useClipboard: Bool {
        get { d.bool(forKey: "useClipboard") }
        set { d.set(newValue, forKey: "useClipboard") }
    }
    static var recordWriting: Bool {
        get { d.bool(forKey: "recordWriting") }
        set { d.set(newValue, forKey: "recordWriting") }
    }
    static var recordWithoutAccept: Bool {
        get { d.object(forKey: "recordWithoutAccept") as? Bool ?? true }
        set { d.set(newValue, forKey: "recordWithoutAccept") }
    }
    /// 0 = off … 1 = max (how many of your own past sentences are shown to the model).
    static var personalization: Double {
        get { d.object(forKey: "personalization") as? Double ?? 0.5 }
        set { d.set(newValue, forKey: "personalization") }
    }
    // Shortcuts
    static var includeTrailingSpace: Bool {
        get { d.bool(forKey: "includeTrailingSpace") }
        set { d.set(newValue, forKey: "includeTrailingSpace") }
    }
    static var includeTrailingPunct: Bool {
        get { d.bool(forKey: "includeTrailingPunct") }
        set { d.set(newValue, forKey: "includeTrailingPunct") }
    }
    /// true = Esc dismisses and pauses suggestions for a few seconds.
    static var escapePauses: Bool {
        get { d.object(forKey: "escapePauses") as? Bool ?? true }
        set { d.set(newValue, forKey: "escapePauses") }
    }
    private static func shortcut(_ key: String, _ def: Shortcut?) -> Shortcut? {
        if d.object(forKey: key) != nil { return Shortcut(d.string(forKey: key) ?? "") }
        return def
    }
    private static func setShortcut(_ key: String, _ v: Shortcut?) { d.set(v?.string ?? "", forKey: key) }
    static var keyAcceptAll: Shortcut? {
        get { shortcut("keyAcceptAll", Shortcut(code: 48, flags: [], label: "⇥")) }
        set { setShortcut("keyAcceptAll", newValue) }
    }
    static var keyAcceptWord: Shortcut? {
        get { shortcut("keyAcceptWord", Shortcut(code: 48, flags: .option, label: "⇥")) }
        set { setShortcut("keyAcceptWord", newValue) }
    }
    static var keyForce: Shortcut? {
        get { shortcut("keyForce", nil) }
        set { setShortcut("keyForce", newValue) }
    }
    static var keyToggleApp: Shortcut? {
        get { shortcut("keyToggleApp", nil) }
        set { setShortcut("keyToggleApp", newValue) }
    }
    static var keyToggleGlobal: Shortcut? {
        get { shortcut("keyToggleGlobal", Shortcut(code: 8, flags: [.control, .option], label: "C")) }
        set { setShortcut("keyToggleGlobal", newValue) }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("Launch at login failed: \(error)") }
        }
    }

    private static func notify() {
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}
