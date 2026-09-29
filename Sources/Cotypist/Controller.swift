import AppKit
import ApplicationServices
import IOKit.ps

private let syntheticMarker: Int64 = 0x436F7479 // "Coty": tags events we post ourselves

final class Controller {
    static let shared = Controller()

    private let llm = LLM()
    private let overlay = Overlay()
    private var tap: CFMachPort?
    private var debounce: DispatchWorkItem?
    private var generation = 0
    private(set) var suggestion: String?
    /// Set when the suggestion is a typo fix: delete `typo` characters, then type `suggestion`.
    private var fixDelete: Int?
    private var lastError: Bool = false
    var onStatus: ((String) -> Void)?

    // MARK: Event tap

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, _ in
            Controller.shared.handle(type: type, event: event)
        }, userInfo: nil) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        if type != .keyDown { dismiss(); return Unmanaged.passUnretained(event) }

        if ShortcutRecorder.isRecording { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let cg = event.flags
        let flags = cg.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

        if let k = Settings.keyToggleGlobal, k.matches(code: code, cgFlags: cg) {
            DispatchQueue.main.async { Settings.enabled.toggle() }
            return nil
        }
        guard Settings.enabled else { return Unmanaged.passUnretained(event) }

        if let k = Settings.keyToggleApp, k.matches(code: code, cgFlags: cg) {
            DispatchQueue.main.async { self.toggleCurrentAppTemporarily() }
            return nil
        }
        if let k = Settings.keyForce, k.matches(code: code, cgFlags: cg) {
            DispatchQueue.main.async { self.dismiss(); self.trigger(force: true) }
            return nil
        }
        if let s = suggestion {
            if let k = Settings.keyAcceptAll, k.matches(code: code, cgFlags: cg) {
                if let n = fixDelete { applyFix(delete: n, with: s) } else { accept(s) }
                return nil
            }
            if fixDelete == nil, let k = Settings.keyAcceptWord, k.matches(code: code, cgFlags: cg) {
                acceptWord(s)
                return nil
            }
            if code == 53 && flags.isEmpty {   // Esc: clear the suggestion; the app doesn't see this press
                dismiss()
                if Settings.escapePauses { pausedUntil = Date().addingTimeInterval(5) }
                return nil
            }
        }

        dismiss()
        // Ignore shortcuts and pure navigation keys; retrigger only on typing.
        let navKeys: Set<Int64> = [123, 124, 125, 126, 115, 119, 116, 121, 53, 48]
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || navKeys.contains(code) {
            return Unmanaged.passUnretained(event)
        }
        schedule()
        return Unmanaged.passUnretained(event)
    }

    // MARK: Per-app temporary override

    private var pausedUntil = Date.distantPast
    private var overrides: [String: (enabled: Bool, until: Date)] = [:]

    func isAllowed(_ bundleID: String?) -> Bool {
        if let id = bundleID, let o = overrides[id] {
            if o.until > Date() { return o.enabled }
            overrides[id] = nil
        }
        return Settings.allowed(bundleID: bundleID)
    }

    private func toggleCurrentAppTemporarily() {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        overrides[id] = (enabled: !isAllowed(id), until: Date().addingTimeInterval(300))
        dismiss()
    }

    // MARK: Suggest

    private func schedule() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.trigger() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Settings.debounceMs), execute: w)
    }

    private var lastPrefix = ""

    private func trigger(force: Bool = false) {
        guard Date() >= pausedUntil || force else { return }
        guard let ctx = AX.readContext() else { return }
        guard isAllowed(ctx.bundleID) else { return }
        lastPrefix = ctx.prefix
        if Settings.recordWriting, Settings.recordWithoutAccept,
           let sentence = History.lastSentence(ctx.prefix, completed: true) { History.shared.add(sentence) }
        if Settings.pauseLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        if Settings.pauseOnBattery, Controller.onBattery { return }

        if Settings.typoGuard, let word = Controller.currentWord(ctx.prefix), let typo = Controller.checkTypo(word) {
            if Settings.suggestFixes, let fix = typo {
                suggestion = fix; fixDelete = word.count
                overlay.show(fix, at: ctx.caretRect, isFix: true)
            }
            return
        }
        generation += 1
        let gen = generation
        llm.complete(prefix: ctx.prefix, appName: ctx.appName) { [weak self] raw in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                guard let raw else {
                    if Settings.backend == "ollama", !self.lastError { self.lastError = true; self.onStatus?("Ollama unreachable") }
                    return
                }
                if self.lastError { self.lastError = false; self.onStatus?("Ready") }
                let text = Controller.clean(raw, prefix: ctx.prefix)
                guard !text.isEmpty else { return }
                // Caret may have moved while we waited.
                guard let now = AX.readContext(), now.prefix == ctx.prefix else { return }
                self.suggestion = text
                Settings.shown += 1
                self.overlay.show(text, at: now.caretRect)
            }
        }
    }

    private static func clean(_ raw: String, prefix: String) -> String {
        var t = raw.replacingOccurrences(of: "\r", with: "")
        if let nl = t.firstIndex(of: "\n") { t = String(t[..<nl]) }
        // Don't start with a second space if the prefix already ends in one.
        if prefix.last == " ", t.first == " " { t.removeFirst() }
        if t.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return t
    }

    func dismiss() {
        debounce?.cancel()
        generation += 1
        llm.cancel()
        suggestion = nil
        fixDelete = nil
        overlay.hide()
    }

    // MARK: Typo guard

    /// The word being typed, if the caret is right after letters.
    private static func currentWord(_ prefix: String) -> String? {
        let w = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        return w.count >= 3 ? w : nil
    }

    /// nil = looks fine; .some(fix) = suspected typo (fix may be nil if there's no good guess).
    private static func checkTypo(_ word: String) -> String?? {
        let sc = NSSpellChecker.shared
        let all = NSRange(location: 0, length: (word as NSString).length)
        guard sc.checkSpelling(of: word, startingAt: 0).location != NSNotFound else { return nil }
        // Misspelled as-is; fine if it can still grow into a real word.
        if let c = sc.completions(forPartialWordRange: all, in: word, language: nil, inSpellDocumentWithTag: 0), !c.isEmpty {
            return nil
        }
        return .some(sc.correction(forWordRange: all, in: word, language: sc.language(), inSpellDocumentWithTag: 0))
    }

    static var onBattery: Bool {
        guard let t = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else { return false }
        return t == kIOPMBatteryPowerKey
    }

    private func recordAccepted(_ text: String) {
        guard Settings.recordWriting, let sentence = History.lastSentence(lastPrefix + text, completed: false) else { return }
        History.shared.add(sentence)
    }

    private func applyFix(delete n: Int, with text: String) {
        dismiss()
        Settings.fixesApplied += 1
        let src = CGEventSource(stateID: .privateState)
        for _ in 0..<n {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down) else { continue }
                e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                e.post(tap: .cgSessionEventTap)
            }
        }
        type(text)
    }

    // MARK: Accept

    private func acceptWord(_ text: String) {
        // Leading whitespace, then a run of word characters (or, failing that, any non-space run).
        var idx = text.startIndex
        let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber || "'’-".contains($0) }
        while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
        if idx < text.endIndex, isWordChar(text[idx]) {
            while idx < text.endIndex, isWordChar(text[idx]) { idx = text.index(after: idx) }
        } else {
            while idx < text.endIndex, !text[idx].isWhitespace { idx = text.index(after: idx) }
        }
        if Settings.includeTrailingPunct {
            while idx < text.endIndex, !text[idx].isWhitespace, !isWordChar(text[idx]) { idx = text.index(after: idx) }
        }
        if Settings.includeTrailingSpace, idx < text.endIndex, text[idx] == " " { idx = text.index(after: idx) }
        let word = String(text[..<idx])
        let rest = String(text[idx...])
        dismiss()
        Settings.accepted += 1; Settings.wordsAccepted += 1
        recordAccepted(word)
        type(word)
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Let the target app apply the insert, then re-anchor the remainder at the new caret.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self, self.suggestion == nil, let ctx = AX.readContext() else { return }
            self.suggestion = rest
            self.overlay.show(rest, at: ctx.caretRect)
        }
    }

    private func accept(_ text: String) {
        dismiss()
        recordAccepted(text)
        Settings.accepted += 1
        Settings.wordsAccepted += text.split(whereSeparator: { $0.isWhitespace }).count
        type(text)
    }

    private func type(_ text: String) {
        let src = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            i += 16
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.post(tap: .cgSessionEventTap)
            }
        }
    }
}
