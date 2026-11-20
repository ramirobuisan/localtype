import AppKit
import ApplicationServices
import IOKit.ps

private let syntheticMarker: Int64 = 0x4C635470 // "LcTp": tags events we post ourselves

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
    /// Set while an emoji suggestion is showing: matches, the selected one, and how many characters ":query" spans.
    private var emoji: (items: [Emoji.Item], index: Int, delete: Int, caret: NSRect)?
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
        let isAcceptWord = Settings.keyAcceptWord?.matches(code: code, cgFlags: cg) == true
        let isAcceptAll = Settings.keyAcceptAll?.matches(code: code, cgFlags: cg) == true
        if let e = emoji {
            if isAcceptWord || isAcceptAll {
                acceptEmoji(e.items[e.index], delete: e.delete)
                return nil
            }
            // ↓ / ↑ step through the other matches; arrows reach the app again once the emoji is gone.
            if e.items.count > 1, flags.isEmpty, code == 125 || code == 126 {
                let next = (e.index + (code == 125 ? 1 : e.items.count - 1)) % e.items.count
                emoji?.index = next
                suggestion = e.items[next].char
                overlay.showEmoji(e.items, selected: next, at: e.caret)
                return nil
            }
        }
        if let s = suggestion {
            if let n = fixDelete, isAcceptWord || isAcceptAll {
                applyFix(delete: n, with: s)
                return nil
            }
            // Word first: one press of the word key inserts one word, even if both keys are set the same.
            if isAcceptWord {
                acceptWord(s)
                return nil
            }
            if isAcceptAll {
                accept(s)
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

    func isAllowed(_ bundleID: String?, domain: String? = nil) -> Bool {
        if let id = bundleID, let o = overrides[id] {
            if o.until > Date() { return o.enabled }
            overrides[id] = nil
        }
        return Settings.allowed(bundleID: bundleID, domain: domain)
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
    private var lastApp: String?

    private func trigger(force: Bool = false) {
        guard Date() >= pausedUntil || force else { return }
        guard let ctx = AX.readContext() else { return }
        overlay.fieldStyle = ctx.style
        guard isAllowed(ctx.bundleID, domain: ctx.domain) else { return }
        lastPrefix = ctx.prefix
        lastApp = ctx.bundleID
        if Settings.recordWriting, Settings.recordWithoutAccept,
           let sentence = History.lastSentence(ctx.prefix, completed: true) { History.shared.add(sentence, app: ctx.bundleID) }

        if Settings.emojiCompletion {
            if Settings.emojiEmoticons, let (item, length) = Emoji.emoticon(in: ctx.prefix) {
                emoji = ([item], 0, length, ctx.caretRect)
                suggestion = item.char
                overlay.showEmoji([item], selected: 0, at: ctx.caretRect)
                return
            }
            if let (q, length) = Emoji.query(in: ctx.prefix) {
                let items = Emoji.search(q)
                if !items.isEmpty {
                    emoji = (items, 0, length, ctx.caretRect)
                    suggestion = items[0].char
                    overlay.showEmoji(items, selected: 0, at: ctx.caretRect)
                }
                return   // never run the model on a half-typed ":shortcode"
            }
        }
        if Settings.pauseLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        if Settings.pauseOnBattery, Controller.onBattery { return }
        if Settings.batteryOnDemand, !force, Controller.onBattery { return }

        if Settings.typoGuard, let word = Controller.currentWord(ctx.prefix), let typo = Controller.checkTypo(word) {
            if Settings.suggestFixes, let fix = typo {
                suggestion = fix; fixDelete = word.count
                let typoRect = AX.screenRect(ctx.element, location: ctx.caretIndex - word.count, length: word.count)
                overlay.show(fix, at: ctx.caretRect, isFix: true, typo: typoRect)
            }
            return
        }
        var screen: String?
        if Settings.useScreen {
            ScreenContext.shared.refreshIfStale(pid: ctx.pid, caret: ctx.caretPoint)
            screen = ScreenContext.shared.text(pid: ctx.pid, caret: ctx.caretPoint, excluding: ctx.prefix)
        }
        generation += 1
        let gen = generation
        llm.complete(prefix: ctx.prefix, appName: ctx.appName, screen: screen) { [weak self] raw in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                guard let raw else {
                    if Settings.backend != "embedded", !self.lastError {
                        self.lastError = true
                        self.onStatus?(Settings.backend == "mlxserve" ? "MLX-Serve unreachable" : "Ollama unreachable")
                    }
                    return
                }
                if self.lastError { self.lastError = false; self.onStatus?("Ready") }
                var text = Controller.clean(raw, prefix: ctx.prefix)
                if Settings.currentWordOnly { text = Controller.restOfWord(text, after: ctx.prefix) }
                guard !text.isEmpty else { return }
                // Caret may have moved while we waited.
                guard let now = AX.readContext(), now.prefix == ctx.prefix else { return }
                self.suggestion = text
                Settings.shown += 1
                self.overlay.fieldStyle = now.style
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

    /// "Current word only": the letters that finish the word being typed, or nothing if the caret isn't mid-word.
    static func restOfWord(_ text: String, after prefix: String) -> String {
        guard let last = prefix.last, last.isLetter, let first = text.first, first.isLetter else { return "" }
        return String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
    }

    func dismiss() {
        debounce?.cancel()
        generation += 1
        llm.cancel()
        suggestion = nil
        fixDelete = nil
        emoji = nil
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
        History.shared.add(sentence, app: lastApp)
    }

    private func applyFix(delete n: Int, with text: String) {
        dismiss()
        Settings.fixesApplied += 1
        deleteBackward(n)
        type(text)
    }

    private func acceptEmoji(_ item: Emoji.Item, delete n: Int) {
        dismiss()
        Settings.emojiInserted += 1
        Emoji.recordUse(item.char)
        deleteBackward(n)
        type(item.char)
        Stats.shared.record(item.char, app: lastApp)
    }

    private func deleteBackward(_ n: Int) {
        let src = CGEventSource(stateID: .privateState)
        for _ in 0..<n {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down) else { continue }
                e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                e.flags = []
                e.post(tap: .cgSessionEventTap)
            }
        }
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
        if Settings.punctuationMode == 2 {
            while idx < text.endIndex, !text[idx].isWhitespace, !isWordChar(text[idx]) { idx = text.index(after: idx) }
        }
        if Settings.includeTrailingSpace, idx < text.endIndex, text[idx] == " " { idx = text.index(after: idx) }
        let word = String(text[..<idx])
        let rest = String(text[idx...])
        dismiss()
        Settings.accepted += 1; Settings.wordsAccepted += 1
        recordAccepted(word)
        type(word)
        Stats.shared.record(word, app: lastApp)
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Let the target app apply the insert, then re-anchor the remainder at the new caret.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self, self.suggestion == nil, let ctx = AX.readContext() else { return }
            self.suggestion = rest
            self.overlay.fieldStyle = ctx.style
            self.overlay.show(rest, at: ctx.caretRect)
        }
    }

    private func accept(_ text: String) {
        // "Never" include trailing punctuation: keep it in the suggestion for another press.
        var take = text, rest = ""
        if Settings.punctuationMode == 0 {
            let punct = text.reversed().prefix { $0.isPunctuation && $0 != "'" && $0 != "’" }
            if punct.count < text.count { take = String(text.dropLast(punct.count)); rest = String(punct.reversed()) }
        }
        dismiss()
        recordAccepted(take)
        Settings.accepted += 1
        Settings.wordsAccepted += take.split(whereSeparator: { $0.isWhitespace }).count
        type(take)
        Stats.shared.record(take, app: lastApp)
        guard !rest.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self, self.suggestion == nil, let ctx = AX.readContext() else { return }
            self.suggestion = rest
            self.overlay.fieldStyle = ctx.style
            self.overlay.show(rest, at: ctx.caretRect)
        }
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
