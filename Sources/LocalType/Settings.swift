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
    /// "mlxserve" = MLX-Serve app (default when installed), "embedded" = built-in llama.cpp engine,
    /// "ollama" = external Ollama server.
    static var backend: String {
        get { d.string(forKey: "backend") ?? (MLXServeStore.installed ? "mlxserve" : "embedded") }
        set { d.set(newValue, forKey: "backend"); notify() }
    }
    static var mlxEndpoint: String {
        get { d.string(forKey: "mlxEndpoint") ?? "http://127.0.0.1:11234" }
        set { d.set(newValue, forKey: "mlxEndpoint") }
    }
    /// Model id in MLX-Serve (as listed by /v1/models).
    static var mlxModel: String {
        get { d.string(forKey: "mlxModel") ?? "" }
        set { d.set(newValue, forKey: "mlxModel"); notify() }
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
    /// Token budget for a completion; 0 = "current word only" (finish the word being typed, never the next one).
    static var maxTokens: Int {
        get { d.object(forKey: "maxTokens") as? Int ?? 12 }
        set { d.set(newValue, forKey: "maxTokens") }
    }
    static var currentWordOnly: Bool { maxTokens == 0 }
    /// What a request actually asks for, after "current word only" and the battery setting.
    static var effectiveMaxTokens: Int {
        var n = maxTokens == 0 ? 5 : maxTokens
        if batteryShorter, Controller.onBattery { n = max(4, n * 2 / 3) }
        return n
    }

    // Battery power
    /// On battery, suggestions appear only when asked for with the force-activate shortcut.
    static var batteryOnDemand: Bool {
        get { d.bool(forKey: "batteryOnDemand") }
        set { d.set(newValue, forKey: "batteryOnDemand") }
    }
    /// Model to use on battery (same naming as the current backend's model); "" = the usual one.
    static var batteryModel: String {
        get { d.string(forKey: "batteryModel") ?? "" }
        set { d.set(newValue, forKey: "batteryModel") }
    }
    static var batteryShorter: Bool {
        get { d.bool(forKey: "batteryShorter") }
        set { d.set(newValue, forKey: "batteryShorter") }
    }
    /// The battery model when it applies right now, else nil.
    static var batteryModelNow: String? {
        !batteryModel.isEmpty && Controller.onBattery ? batteryModel : nil
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
    /// 0 = inline ghost text in the field's own font, 1 = in a small bubble.
    static var suggestionStyle: Int {
        get { d.integer(forKey: "suggestionStyle") }
        set { d.set(newValue, forKey: "suggestionStyle") }
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
    /// Per-app rules: bundle ID → completions on/off. Apps without a rule follow `enabledByDefault`.
    static var appRules: [String: Bool] {
        get {
            if let r = d.dictionary(forKey: "appRules") as? [String: Bool] { return r }
            var r: [String: Bool] = [:]   // older builds kept two lists
            for id in d.stringArray(forKey: "disabledApps") ?? [] { r[id] = false }
            for id in d.stringArray(forKey: "enabledApps") ?? [] { r[id] = true }
            return r
        }
        set { d.set(newValue, forKey: "appRules"); notify() }
    }
    /// Per-website rules (any browser): domain → on/off. A rule for "google.com" also covers "mail.google.com".
    static var domainRules: [String: Bool] {
        get { d.dictionary(forKey: "domainRules") as? [String: Bool] ?? [:] }
        set { d.set(newValue, forKey: "domainRules"); notify() }
    }
    /// The most specific website rule that covers `host`, if any.
    static func domainRule(for host: String) -> (domain: String, on: Bool)? {
        let rules = domainRules
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        while true {
            if let on = rules[h] { return (h, on) }
            guard let dot = h.firstIndex(of: "."), h[h.index(after: dot)...].contains(".") else { return nil }
            h = String(h[h.index(after: dot)...])
        }
    }
    static func allowed(bundleID: String?, domain: String? = nil) -> Bool {
        if let domain, let r = domainRule(for: domain) { return r.on }
        if let id = bundleID, let on = appRules[id] { return on }
        return enabledByDefault
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
    /// Text emoticons like ":-)" or "<3" offer the matching emoji.
    static var emojiEmoticons: Bool {
        get { d.object(forKey: "emojiEmoticons") as? Bool ?? true }
        set { d.set(newValue, forKey: "emojiEmoticons") }
    }
    /// 0 = neutral (yellow), 1…5 = light … dark.
    static var emojiSkinTone: Int {
        get { d.integer(forKey: "emojiSkinTone") }
        set { d.set(newValue, forKey: "emojiSkinTone") }
    }
    /// Also offer the neutral variant next to the preferred skin tone.
    static var emojiIncludeNeutral: Bool {
        get { d.bool(forKey: "emojiIncludeNeutral") }
        set { d.set(newValue, forKey: "emojiIncludeNeutral") }
    }
    /// 0 = gender-neutral, 1 = female, 2 = male (people emoji with separate variants).
    static var emojiGender: Int {
        get { d.integer(forKey: "emojiGender") }
        set { d.set(newValue, forKey: "emojiGender") }
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
    /// Trailing punctuation when accepting: 0 = never, 1 = only with the full completion, 2 = always.
    /// Punctuation left out stays in the suggestion, so another press inserts it.
    static var punctuationMode: Int {
        get { d.object(forKey: "punctuationMode") as? Int ?? (d.bool(forKey: "includeTrailingPunct") ? 2 : 1) }
        set { d.set(newValue, forKey: "punctuationMode") }
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
        get { shortcut("keyAcceptAll", Shortcut(code: 48, flags: .option, label: "⇥")) }
        set { setShortcut("keyAcceptAll", newValue) }
    }
    static var keyAcceptWord: Shortcut? {
        get { shortcut("keyAcceptWord", Shortcut(code: 48, flags: [], label: "⇥")) }
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
