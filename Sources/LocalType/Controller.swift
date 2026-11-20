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
        // Ask each app that comes to the front for its accessibility tree (needed by Chromium/Electron apps).
        if let front = NSWorkspace.shared.frontmostApplication { AX.enableAccessibility(for: front) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { AX.enableAccessibility(for: app) }
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
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
        if type == .leftMouseUp {   // a click or drag may have just selected a word (synonyms)
            DispatchQueue.main.async { self.scheduleSelectionCheck() }
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
        // A numbered list (alternatives or synonyms) is open: 1–n picks, Esc closes just the list.
        if choices.isVisible {
            let digits: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5]
            if flags.isEmpty, let n = digits[code], n <= choices.items.count {
                let pick = choices.items[n - 1]
                DispatchQueue.main.async { self.applyChoice(pick) }
                return nil
            }
            if code == 53 && flags.isEmpty {
                DispatchQueue.main.async { self.closeChoices() }
                return nil
            }
        }
        if let k = Settings.keyAlternatives, k.matches(code: code, cgFlags: cg), suggestion != nil {
            DispatchQueue.main.async { self.showAlternatives() }
            return nil
        }
        if let k = Settings.keySynonyms, k.matches(code: code, cgFlags: cg) {
            DispatchQueue.main.async { self.showSynonyms() }
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
        if flags.contains(.maskShift), [123, 124, 125, 126].contains(code) {   // ⇧-arrows extend a selection
            DispatchQueue.main.async { self.scheduleSelectionCheck() }
        }
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
    /// The current suggestion belongs to the Setup window's "Try it" box: not recorded anywhere.
    private var practice = false
    private var lastApp: String?
    private var lastElement: AXUIElement?

    private func trigger(force: Bool = false) {
        guard Date() >= pausedUntil || force else { return }
        guard let ctx = AX.readContext() else { return }
        overlay.fieldStyle = ctx.style
        overlay.coverText = ctx.hasTextAfter
        overlay.coverUntilX = ctx.textAfterMaxX
        overlay.backdrop = nil
        practice = ctx.isPractice
        if Settings.matchAppearance, !ctx.isPractice {
            // Strip to the right of the caret, where the suggestion will go; sampled while the model works.
            let p = ctx.caretPoint
            Backdrop.sample(CGRect(x: p.x + 1, y: p.y - ctx.lineHeight / 2, width: 160, height: ctx.lineHeight)) { [weak self] c in
                guard let self, let c else { return }
                self.overlay.backdrop = c
                self.overlay.refresh()
            }
        }
        guard isAllowed(ctx.bundleID, domain: ctx.domain) else { return }
        lastPrefix = ctx.prefix
        lastApp = ctx.bundleID
        lastElement = ctx.element
        if !ctx.isPractice { recordNewSentences(ctx.prefix, element: ctx.element, app: ctx.bundleID) }

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
                let typoRect = ctx.isPractice ? nil : AX.screenRect(ctx.element, location: ctx.caretIndex - word.count, length: word.count)
                overlay.show(fix, at: ctx.caretRect, isFix: true, typo: typoRect)
            }
            return
        }
        var screen: String?
        if Settings.useScreen, !ctx.isPractice {
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
                if Settings.alternativesMode == 1 { self.scheduleAlternatives(for: text) }
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
    /// Only real words: this mode is spelling help, so a garbled completion is worse than none.
    static func restOfWord(_ text: String, after prefix: String) -> String {
        guard let last = prefix.last, last.isLetter, let first = text.first, first.isLetter else { return "" }
        let rest = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        return Spelling.isWord(tail + rest) ? rest : ""
    }

    // MARK: Labs: alternative words and synonyms

    static let alternativesPrompt = """
        You suggest alternative ways to continue text that is being typed. Give 5 different continuations for the text \
        at the marker ‸. Each must fit directly after the last word and continue the same sentence (start in lowercase \
        unless a new sentence begins), be 1 to 3 words long, and start with a different word. One per line: no numbering, \
        no quotes, no explanations. Match the language and tone.
        """
    static let synonymsPrompt = """
            You are a thesaurus. Give 5 words or short phrases that could replace the text marked with « » in the passage, \
            with the same meaning and the same grammatical form (tense, number, gender). One per line: no numbering, no quotes, \
            no explanations. Use the passage's language.
            """

    private let choices = ChoicesPanel()
    private enum ChoiceKind { case alternatives, synonyms(String) }
    private var choiceKind: ChoiceKind?
    private var choiceTimer: DispatchWorkItem?
    private let listLLM = LLM()

    private func closeChoices() {
        choiceTimer?.cancel()
        listLLM.cancelList()
        choices.hide()
        choiceKind = nil
    }

    /// After a short pause on the same suggestion, offer other ways to continue.
    private func scheduleAlternatives(for text: String) {
        choiceTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.suggestion == text else { return }
            self.showAlternatives()
        }
        choiceTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1200), execute: w)
    }

    private func showAlternatives() {
        guard LLM.supportsLists, let current = suggestion, emoji == nil, fixDelete == nil, let ctx = AX.readContext() else { return }
        let system = Controller.alternativesPrompt
        let user = "[Writing in \(ctx.appName ?? "an app")]\n\n" + ctx.prefix + "‸"
        choiceKind = .alternatives
        listLLM.list(system: system, user: user, count: 5) { [weak self] items in
            DispatchQueue.main.async {
                guard let self, self.suggestion == current, case .alternatives? = self.choiceKind else { return }
                let options = items.map { MLXServeCompletion.join(Controller.continuingCase($0, after: ctx.prefix), after: ctx.prefix) }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !options.isEmpty else { return }
                self.choices.show(options, heading: "Other words", below: ctx.caretRect)
            }
        }
    }

    /// A selection may have just been made: look for one shortly (automatic synonyms only).
    private func scheduleSelectionCheck() {
        guard Settings.synonymsMode == 1, Settings.enabled else { return }
        choiceTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.showSynonyms() }
        choiceTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(700), execute: w)
    }

    private func showSynonyms() {
        guard Settings.synonymsMode != 0, LLM.supportsLists, let sel = AX.readSelection() else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(sel.element, &pid)
        guard isAllowed(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, domain: AX.webDomain(of: sel.element)) else { return }
        let system = Controller.synonymsPrompt
        let user = "Passage: …\(sel.before)«\(sel.text)»\(sel.after)…\n\nReplace: \(sel.text)"
        choiceKind = .synonyms(sel.text)
        listLLM.list(system: system, user: user, count: 5) { [weak self] items in
            DispatchQueue.main.async {
                guard let self, case .synonyms(let original)? = self.choiceKind, original == sel.text else { return }
                let options = items.filter { $0.caseInsensitiveCompare(sel.text) != .orderedSame }
                guard !options.isEmpty, AX.readSelection()?.text == sel.text else { return }   // selection still there
                self.choices.show(options.map { Controller.matchCase($0, to: sel.text) }, heading: "Synonyms", below: sel.rect)
            }
        }
    }

    /// Mid-sentence, "Moving forward" → "moving forward" (only when the lowercase word exists, so "I" and names stay).
    static func continuingCase(_ option: String, after prefix: String) -> String {
        let end = prefix.trimmingCharacters(in: .whitespaces).last
        guard let end, !".!?\n:".contains(end), let first = option.first, first.isUppercase else { return option }
        let word = String(option.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        guard word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I’"), word.count > 1 || word == "A",
              Spelling.isWord(word.lowercased()) else { return option }
        return option.prefix(1).lowercased() + option.dropFirst()
    }

    /// "Big" → "Large", "BIG" → "LARGE".
    static func matchCase(_ word: String, to original: String) -> String {
        if original.count > 1, original == original.uppercased(), original != original.lowercased() { return word.uppercased() }
        if let f = original.first, f.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }

    private func applyChoice(_ text: String) {
        let kind = choiceKind
        closeChoices()
        switch kind {
        case .alternatives?:
            dismiss()
            recordAccepted(text)
            Settings.accepted += 1
            type(text)
            Stats.shared.record(text, app: lastApp)
        case .synonyms(let original)?:
            guard AX.readSelection()?.text == original else { return }   // typing replaces the still-selected text
            type(text)
        case nil:
            break
        }
    }

    func dismiss() {
        closeChoices()
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

    /// Starts of sentences in which a suggestion was accepted (for "record only where I accepted one").
    private var acceptedSentenceStarts: [String] = []

    /// Typing history bookkeeping: the field and text seen last time, so only newly written text is recorded.
    private var historyElement: AXUIElement?
    private var historyPrefix = ""

    /// Saves every sentence finished in the text added to this field since the last look. The first look at a
    /// field only sets the baseline, so text that was already there (a quoted email, pasted text) is never saved.
    private func recordNewSentences(_ text: String, element: AXUIElement?, app: String?) {
        guard Settings.recordWriting else { return }
        defer { historyPrefix = text; historyElement = element }
        guard let element, let prev = historyElement, CFEqual(prev, element) else { return }
        let common = zip(text, historyPrefix).prefix { $0 == $1 }.count
        guard common < text.count else { return }
        let from = text.index(text.startIndex, offsetBy: common)
        var i = from
        while i < text.endIndex {
            let next = text.index(after: i)
            // A sentence end: . ! or ? followed by whitespace or the end ("3.5" and "e.g" don't count).
            if ".!?".contains(text[i]), next == text.endIndex || text[next].isWhitespace,
               let sentence = History.lastSentence(String(text[...i]), completed: true) {
                let accepted = acceptedSentenceStarts.contains { sentence.hasPrefix($0) }
                if Settings.recordWithoutAccept || accepted { History.shared.add(sentence, app: app) }
            }
            i = next
        }
    }

    private func recordAccepted(_ text: String) {
        guard Settings.recordWriting, !practice else { return }
        let full = lastPrefix + text
        if let partial = History.lastSentence(full, completed: false) {
            acceptedSentenceStarts.append(partial)
            if acceptedSentenceStarts.count > 30 { acceptedSentenceStarts.removeFirst() }
        }
        // Record now if the accepted text finished a sentence: the next keystroke may never come.
        recordNewSentences(full, element: lastElement, app: lastApp)
        lastPrefix = full
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
        if !practice { Stats.shared.record(item.char, app: lastApp) }
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
        if !practice { Stats.shared.record(word, app: lastApp) }
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Let the target app apply the insert, then re-anchor the remainder at the new caret.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self, self.suggestion == nil, let ctx = AX.readContext() else { return }
            self.lastPrefix = ctx.prefix
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
        if !practice { Stats.shared.record(take, app: lastApp) }
        guard !rest.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self, self.suggestion == nil, let ctx = AX.readContext() else { return }
            self.lastPrefix = ctx.prefix
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
