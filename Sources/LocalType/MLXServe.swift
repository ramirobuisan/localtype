import AppKit
import NaturalLanguage

/// Model source backed by a running MLX-Serve app (OpenAI-compatible server, default 127.0.0.1:11234).
/// MLX-Serve owns the models: LocalType lists its chat models, asks it to load the chosen one,
/// and never downloads or deletes anything itself.
final class MLXServeStore: ModelStore {
    static let shared = MLXServeStore()
    static let appURL = URL(fileURLWithPath: "/Applications/MLX-Serve.app")
    static var installed: Bool { FileManager.default.fileExists(atPath: appURL.path) }

    let catalog: [(id: String, note: String)] = []
    let placeholder = "Add models in the MLX-Serve app"
    let canImport = false
    let canDownload = false
    let canDelete = false
    let isBusy = false

    /// Chat models from the last listing, and which of them are loaded in memory.
    private(set) var loaded: Set<String> = []

    var activeName: String {
        get { Settings.mlxModel }
        set {
            Settings.mlxModel = newValue
            if !loaded.contains(newValue) { load(newValue) }
        }
    }

    private func url(_ path: String) -> URL? { URL(string: Settings.mlxEndpoint + path) }

    private func ping(_ done: @escaping (Bool) -> Void) {
        guard let u = url("/v1/models") else { return done(false) }
        var r = URLRequest(url: u); r.timeoutInterval = 2
        URLSession.shared.dataTask(with: r) { _, resp, err in
            DispatchQueue.main.async { done(err == nil && (resp as? HTTPURLResponse)?.statusCode == 200) }
        }.resume()
    }

    /// Makes sure the server answers, opening the MLX-Serve app (never closing it) if it isn't running.
    func prepare(_ done: @escaping (String?) -> Void) {
        ping { up in
            if up { return done(nil) }
            guard MLXServeStore.installed, Settings.mlxEndpoint.contains("127.0.0.1") || Settings.mlxEndpoint.contains("localhost") else {
                return done("MLX-Serve isn't reachable at \(Settings.mlxEndpoint).")
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: MLXServeStore.appURL, configuration: cfg) { _, _ in }
            var tries = 0
            func retry() {
                self.ping { up in
                    if up { return done(nil) }
                    tries += 1
                    if tries > 30 { return done("MLX-Serve didn't start. Open it and try again.") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
        }
    }

    func list(_ done: @escaping ([InstalledModel]?) -> Void) {
        guard let u = url("/v1/models") else { return done(nil) }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else { return DispatchQueue.main.async { done(nil) } }
            var models: [InstalledModel] = [], loaded = Set<String>()
            for m in arr {
                guard let id = m["id"] as? String, (m["capabilities"] as? [String])?.contains("chat") == true else { continue }
                models.append(InstalledModel(name: id, size: (m["bytes_on_disk"] as? NSNumber)?.int64Value ?? 0))
                if m["loaded"] as? Bool == true { loaded.insert(id) }
            }
            DispatchQueue.main.async {
                self.loaded = loaded
                // Loaded models first: they answer immediately.
                done(models.sorted { (loaded.contains($0.name) ? 0 : 1, $0.name) < (loaded.contains($1.name) ? 0 : 1, $1.name) })
            }
        }.resume()
    }

    /// Picks a model when none is set (or the saved one is gone): a loaded one if possible.
    func autoSelect(_ done: @escaping () -> Void) {
        list { models in
            let names = (models ?? []).map(\.name)
            if !names.contains(Settings.mlxModel), let pick = names.first(where: { self.loaded.contains($0) }) ?? names.first {
                Settings.mlxModel = pick
            }
            done()
        }
    }

    func isActive(_ installed: String) -> Bool { installed == Settings.mlxModel }

    private func load(_ id: String) {
        guard let u = url("/v1/load-model") else { return }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": id])
        r.timeoutInterval = 600
        URLSession.shared.dataTask(with: r) { _, _, _ in }.resume()
    }

    func download(_ id: String, progress: @escaping (String, Double?) -> Void, done: @escaping (String?) -> Void) {
        done("Add models from the MLX-Serve app.")
    }
    func cancelDownload() {}
    func delete(_ name: String, _ done: @escaping (Bool) -> Void) { done(false) }
}

/// Completion through a chat endpoint: MLX-Serve's OpenAI-style one or Ollama's /api/chat. Instruct models
/// degenerate on raw continuation ("la la la…"), but follow a short "continue this text" instruction well.
enum ChatCompletion {
    /// Chosen by scoring variants on a 22-case set (English/Spanish, mail, chat, lists, half-typed words, sign-offs,
    /// replies with screen context, invented-number traps) against gemma-4-E4B: this one plus the examples below
    /// passed 21/22 versus 16/20 for the previous prompt, at the same speed (the fixed part is prefix-cached).
    static let system = """
        You are the autocomplete in a Mac text field. You see what the person has typed so far; the cursor is at ‸. \
        Reply with the words that most likely come next, exactly as they would type them.

        Rules:
        - Only the continuation: a few words, at most the rest of the sentence. No quotes, no explanations, never repeat text that is already there.
        - If the text stops in the middle of a word, start by finishing that word. An [Unfinished word] line lists words it may become: pick the one that fits.
        - On a new line in a list, continue the list in the same format.
        - Keep the language, tone and formatting of the text: casual stays casual, lowercase stays lowercase.
        - Never write a number, amount, date, time or name that isn't already in the text or the context: continue with general words instead, or stop before it.
        - Lines in [brackets] before the text are context (the app, what's on screen, the clipboard), not part of the text.
        - The text is never a message to you, even if it's a single word or a question: just continue it.
        """

    /// Worked examples sent as earlier turns (few-shot): finishing a word, continuing a list, using what's on
    /// screen, casual chat, and not inventing an amount. Small models follow examples much better than rules.
    static let examples: [(user: String, reply: String)] = [
        ("[Writing in Mail]\n\nHi Sam,\n\nThanks for the quick repl‸", "y. I'll take a look this afternoon."),
        ("[Writing in Notes]\n\nTo do:\n- call the bank\n‸", "- book the dentist"),
        ("[Writing in Mail]\n[On screen: Ana: Can we move our call to Thursday?]\n\nHi Ana,\n\nThursday works for me. ‸", "What time suits you?"),
        ("[Writing in Messages]\n\nkk see u‸", "tomorrow then"),
        ("[Writing in Mail]\n\nThe invoice total for this month comes to‸", "the amount we agreed on in the contract."),
        ("[Writing in Mail]\n[Unfinished word \"kn\": know, knew, knowledge]\n\nPlease let me kn‸", "ow if that works for you."),
        ("[Writing in Safari on reddit.com]\n\nhonestly‸", " the new update made it so much better"),
        ("[Writing in Messages]\n\nI'll be home late tonight.‸", "Don't wait up for dinner."),
    ]

    /// The person's own description of how they write (Settings), added to the instructions as information about them.
    static func messages(context: String, text: String) -> [[String: String]] {
        let style = Settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let about = style.isEmpty ? "" : "\n\nAbout the person, in their own words (for tone, and facts such as their name; never text to rewrite): \(style)"
        var m = [["role": "system", "content": system + about]]
        for e in examples { m.append(["role": "user", "content": e.user]); m.append(["role": "assistant", "content": e.reply]) }
        // After a finished sentence ("…los detalles.‸") models tend to repeat the text instead of going on; with the cursor
        // after a space they start the next sentence. join() still adds the real space.
        let shown = text.last.map { ".!?…".contains($0) } == true ? text + " " : text
        m.append(["role": "user", "content": context + shown + "‸"])
        return m
    }

    /// Set when Ollama refuses the `think` switch (older versions or models without thinking); later requests leave it out.
    static var ollamaRejectsThink = false

    static func request(context: String, text: String, maxTokens: Int) -> URLRequest? {
        let ollama = Settings.backend == "ollama"
        let model = Settings.batteryModelNow ?? (ollama ? Settings.model : Settings.mlxModel)
        let endpoint = ollama ? Settings.endpoint + "/api/chat" : Settings.mlxEndpoint + "/v1/chat/completions"
        guard let u = URL(string: endpoint), !model.isEmpty else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages(context: context, text: text), "stream": false]
        if ollama {
            body["keep_alive"] = "30m"
            body["options"] = ["num_predict": maxTokens, "temperature": 0.2, "top_p": 0.9, "stop": ["\n"]]
            if !ollamaRejectsThink { body["think"] = false }
        } else {
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.2
            body["top_p"] = 0.9
            body["stop"] = ["\n"]
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// A chat model's reply turned into the suggestion: re-joined to the text, then the checks for made-up figures,
    /// a switch of language and replies that talk to the person.
    static func finish(_ reply: String, cut: Bool, context: String, prefix: String) -> String {
        var s = join(reply, after: prefix, cut: cut)
        s = cutRunOn(cutAtBracket(s, prefix: prefix), prefix: prefix)
        s = dropRepeats(s, prefix: prefix)
        s = dropInventedFigures(s, context: context + prefix)
        return dropAssistantReply(dropLanguageSwitch(s, prefix: prefix), prefix: prefix)
    }

    /// The reply starts by repeating the end of the text, maybe from its start and with other punctuation ("¡Nos
    /// vemos mañana en la universidad!" after "Nos vemos mañana en la universi"). Returns what follows the repeated
    /// part (for a half-typed last word, from inside that word: "dad!"), or nil when there's no repeat.
    static func stripEcho(_ reply: String, prefix: String) -> String? {
        func norm(_ w: Substring) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let pw = prefix.split(whereSeparator: \.isWhitespace).map(norm).filter { !$0.isEmpty }
        let rw = reply.split(whereSeparator: \.isWhitespace)
        let midWord = prefix.last?.isLetter == true
        for k in stride(from: min(8, pw.count, rw.count), through: 2, by: -1) {
            let tail = Array(pw.suffix(k))
            guard zip(rw.prefix(k - 1), tail.dropLast()).allSatisfy({ norm($0) == $1 }) else { continue }
            let word = rw[k - 1], last = tail[k - 1]
            if norm(word) == last {
                return String(reply[word.endIndex...])
            }
            // The half-typed word, finished inside the repeat: keep the rest of that word.
            if midWord, norm(word).hasPrefix(last), let start = word.firstIndex(where: { $0.isLetter || $0.isNumber }) {
                var i = start, matched = 0
                while i < word.endIndex, matched < last.count {
                    if word[i].isLetter || word[i].isNumber { matched += 1 }
                    i = word.index(after: i)
                }
                return String(reply[i...])
            }
        }
        return nil
    }

    /// Square brackets the text doesn't use are the model's (made-up context lines, "[the amount]"): cut there.
    static func cutAtBracket(_ s: String, prefix: String) -> String {
        guard !prefix.contains("["), let b = s.firstIndex(of: "[") else { return s }
        let kept = String(s[..<b])
        return kept.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(kept.reversed().drop { $0 == " " }.reversed())
    }

    /// Cuts where the model runs on into a new sentence without punctuation, often a reply to the text ("repl" +
    /// "y You're welcome!", "reu" + "nión Mañana tengo…"): a capitalised common word right after a lowercase letter.
    /// Names aren't common words in lowercase ("Laura", "Madrid"); "I", all-caps words, months and days are exempt.
    static func cutRunOn(_ s: String, prefix: String) -> String {
        let exempt: Set<String> = ["i", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january",
                                   "february", "march", "april", "may", "june", "july", "august", "september", "october",
                                   "november", "december"]
        let chars = Array(s)
        for i in chars.indices where chars[i] == " " && i + 1 < chars.count && chars[i + 1].isUppercase {
            guard let before = i > 0 ? chars[i - 1] : prefix.last, before.isLetter, before.isLowercase else { continue }
            var j = i + 1
            while j < chars.count, chars[j].isLetter || chars[j] == "'" || chars[j] == "’" { j += 1 }
            let word = String(chars[(i + 1)..<j])
            let base = word.lowercased().split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? ""
            guard word != word.uppercased(), !exempt.contains(base), Spelling.isCommonWord(word.lowercased(), in: prefix) else { continue }
            let kept = String(chars[..<i])
            return kept.trimmingCharacters(in: .whitespaces).isEmpty ? "" : kept
        }
        return s
    }

    /// A suggestion of three or more words that's already in the text ("Steps: 1. Open the app…" + "1. Open the app").
    static func dropRepeats(_ s: String, prefix: String) -> String {
        func norm(_ x: String) -> String {
            String(x.lowercased().map { $0.isWhitespace ? " " : $0 }.filter { $0.isLetter || $0.isNumber || $0 == " " })
                .split(separator: " ").joined(separator: " ")
        }
        let t = norm(s)
        guard t.split(separator: " ").count >= 3 else { return s }
        return norm(prefix).contains(t) ? "" : s
    }

    /// When the text ends in the middle of a word, a context line with the words it may become, from the dictionary
    /// in the text's language ("tar" → tarde, tarjeta, tarta…). Small models finish half-words badly on their own
    /// ("esta tar" → "che", "a contarte"); with the options listed they pick the one that fits.
    /// Only where the model needs it: short fragments ("reu") and rare words that usually start a longer one ("tar").
    /// Longer fragments it finishes well by itself, and a list there nudges it off the right form ("forw" + "arding").
    static func unfinishedWordHint(_ prefix: String) -> String? {
        guard let tail = fragment(prefix), tail.count <= 3 || Spelling.isWord(tail, in: prefix) else { return nil }
        var seen = Set<String>(), words: [String] = []
        for w in Spelling.completions(of: tail, in: prefix)
        where w.count > tail.count && w.lowercased().hasPrefix(tail.lowercased()) && !w.contains("'") && seen.insert(w.lowercased()).inserted {
            words.append(tail + w.dropFirst(tail.count))   // as typed: "Universi" → "Universidad"
            if words.count == 6 { break }
        }
        return words.isEmpty ? nil : "[Unfinished word \"\(tail)\": \(words.joined(separator: ", "))]\n"
    }

    /// The half-typed word the text ends in: letters that aren't a word yet ("docum"), or a rare lowercase word that's
    /// usually the start of a longer one ("tar" → "tarde"). Common words and names ("con", "Madrid") don't count.
    static func fragment(_ prefix: String) -> String? {
        guard let last = prefix.last, last.isLetter else { return nil }
        let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        guard tail.count >= 2 else { return nil }
        // The end of a contraction ("I'll", "we're"), not a word of its own: "ll" isn't the start of "llama".
        if let before = prefix.dropLast(tail.count).last, before == "'" || before == "’" { return nil }
        if tail.first?.isUppercase == true { return Spelling.isWord(tail) ? nil : tail }   // a name in any language
        if !Spelling.isWord(tail, in: prefix) { return tail }
        return Spelling.isCommonWord(tail, in: prefix) ? nil : tail
    }

    /// The model finished a half-typed word into something that's neither a usual completion nor a common word
    /// ("esta tar" + "je para…" → "tarje", a rare verb form): a garbled try at the word the context calls for. Use the
    /// dictionary's most common completion and keep the rest of the reply ("de para…"). When the reply instead starts
    /// a new common word ("apprec" + "your help"), completeIgnoredWord keeps it.
    private static func replaceUnlikelyWord(_ prefix: String, _ reply: String) -> String? {
        guard let tail = fragment(prefix) else { return nil }
        let head = String(reply.prefix { $0.isLetter })
        guard !head.isEmpty, head.first?.isLowercase == true else { return nil }
        let joined = tail + head
        let candidates = Spelling.completions(of: tail, in: prefix)
        if candidates.contains(where: { $0.caseInsensitiveCompare(joined) == .orderedSame }) || Spelling.isCommonWord(joined, in: prefix) {
            return nil
        }
        // The model skipped the half-word and went on with a phrase of its own: completeIgnoredWord keeps that phrase.
        if !Spelling.isWord(joined, in: prefix), Spelling.isCommonWord(head, in: prefix),
           reply.dropFirst(head.count).contains(where: \.isLetter) { return nil }
        guard let top = candidates.first(where: { $0.count > tail.count && $0.lowercased().hasPrefix(tail.lowercased()) && !$0.contains("'") })
        else { return nil }
        return String(top.dropFirst(tail.count)) + reply.dropFirst(head.count)
    }

    /// Replies where the model talks to the person instead of continuing their text ("I'm not sure what you mean
    /// by 'hole'", "Could you provide more context?"). Short texts invite this; drop them.
    static func dropAssistantReply(_ suggestion: String, prefix: String) -> String {
        let meta = #"(?i)(what (you|do you) mean by|could you (please )?(clarify|provide)|provide more (context|details|information)|as an ai\b|language model|i'm not sure what you|you'?re welcome|i'?m sorry to hear|sorry to hear that|i (don'?t|do not) understand|i'?m here to help|no entiendo|estoy aqu[ií] para ayudar|qu[eé] quieres decir con|a qu[eé] te refieres|m[aá]s contexto|no estoy segur[oa] de (qu[eé]|lo que)|como (una )?ia\b|modelo de lenguaje)"#
        guard suggestion.range(of: meta, options: .regularExpression) != nil else { return suggestion }
        // A longer text that itself is a conversation reply may legitimately say this; a few words never do.
        let quotesText = prefix.split(whereSeparator: \.isWhitespace).suffix(3).contains { w in
            w.count >= 3 && suggestion.localizedCaseInsensitiveContains("\"\(w.trimmingCharacters(in: .punctuationCharacters))")
        }
        return prefix.split(whereSeparator: \.isWhitespace).count <= 6 || quotesText ? "" : suggestion
    }

    /// When neither the text nor its context mentions any figure, a suggested amount, percentage or long number
    /// is made up ("revenue was" → "$15,000"): cut the suggestion just before it. Small numbers ("in 5 minutes") stay.
    static func dropInventedFigures(_ reply: String, context: String) -> String {
        guard !context.contains(where: \.isNumber) else { return reply }
        let words = reply.split(separator: " ", omittingEmptySubsequences: false)
        guard let i = words.firstIndex(where: { w in
            w.contains(where: { "$€£¥%".contains($0) }) || w.filter(\.isNumber).count >= 3
        }) else { return reply }
        var kept = words[..<i].joined(separator: " ")
        while let l = kept.last, l == " " || l == "," { kept.removeLast() }
        return kept.trimmingCharacters(in: .whitespaces).isEmpty ? "" : kept
    }

    /// The model sometimes switches language mid-sentence ("Could you plea" → "se me gustaría…"). When the text and
    /// the suggestion are confidently in different languages, keep only what finishes the current word, else nothing.
    static func dropLanguageSwitch(_ suggestion: String, prefix: String) -> String {
        func language(_ s: String) -> (NLLanguage, Double)? {
            let r = NLLanguageRecognizer()
            r.languageConstraints = [.english, .spanish, .french, .german, .italian, .portuguese]
            r.processString(s)
            return r.languageHypotheses(withMaximum: 1).first.map { ($0.key, $0.value) }
        }
        let tail = String(prefix.suffix(200))
        guard suggestion.split(separator: " ").count >= 3, tail.split(separator: " ").count >= 2,
              let (textLang, p1) = language(tail), let (sugLang, p2) = language(suggestion),
              textLang != sugLang, p1 > 0.6, p2 > 0.6 else { return suggestion }
        let finish = String(suggestion.prefix { $0.isLetter })   // the part that completes a half-typed word
        return prefix.last?.isLetter == true && !suggestion.hasPrefix(" ") ? finish : ""
    }

    /// The reply text, and whether it was cut off by the token limit.
    static func parse(_ data: Data) -> (text: String, cut: Bool)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let choice = (obj["choices"] as? [[String: Any]])?.first,           // OpenAI style (MLX-Serve)
           let msg = (choice["message"] as? [String: Any])?["content"] as? String {
            return (msg, choice["finish_reason"] as? String == "length")
        }
        if let msg = (obj["message"] as? [String: Any])?["content"] as? String {  // Ollama
            return (msg, obj["done_reason"] as? String == "length")
        }
        return nil
    }

    /// Chat models reply as a separate message, so they drop the joining space, sometimes echo the end of
    /// the text, or wrap the reply in quotes. Turn the reply into what should be typed after `prefix`.
    static func join(_ reply: String, after prefix: String, cut: Bool = false) -> String {
        var reply = reply
        // Cut off by the token limit right after an apostrophe ("before Friday'"): drop the dangling mark.
        if cut, let last = reply.last, last == "'" || last == "’", reply.dropLast().last?.isLetter == true { reply.removeLast() }
        var t = reply.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "‸", with: "")
        if let nl = t.firstIndex(of: "\n") { t = String(t[..<nl]) }
        t = t.trimmingCharacters(in: .whitespaces)
        for q in ["\"", "“", "”", "'", "`"] where t.hasPrefix(q) && !prefix.hasSuffix(q) { t.removeFirst() }
        if let last = t.last, "\"”`".contains(last), !t.dropLast().contains(last) { t.removeLast() }
        // Template placeholders ("[Your Name]", "[End of letter]") are never what the user would type.
        if t.hasPrefix("["), t.hasSuffix("]") { return "" }
        if t.hasPrefix("...") || t.hasPrefix("…") { t = String(t.drop { $0 == "." || $0 == "…" }).trimmingCharacters(in: .whitespaces) }

        if let rest = stripEcho(t, prefix: prefix) {
            // The spacing after the repeat is redone below, as for any reply ("detalles." + " ¿Te" had two spaces).
            t = rest.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return "" }
        }
        guard let first = t.first, let last = prefix.last else { return t }
        if last == "\n" { return continueList(t, after: prefix) }
        if last.isWhitespace { return t }
        // Punctuation that attaches to the previous word.
        if ".,;:!?)]}…%".contains(first) || first == "'" || first == "’" { return t }
        if last.isLetter || last.isNumber {
            // Mid-word: the reply finishes the word ("I'll send the docum" + "ents").
            t = repairOverlap(prefix, t)
            if let fixed = replaceUnlikelyWord(prefix, t) { return fixed }
            if let fixed = completeIgnoredWord(prefix, t) { return fixed }
            if finishesWord(prefix, t) { return t }
            // A new word right after a complete one. A lowercase non-word there is a garbled attempt at finishing
            // the word ("esta tar" + "che", "Could you plea" + "sease"): show nothing rather than " che".
            let head = String(t.prefix { $0.isLetter })
            if head.count >= 2, head.first?.isLowercase == true, !Spelling.isWord(head) { return "" }
            return " " + t
        }
        if "([{\"“‘/-".contains(last) { return t }
        return " " + t
    }

    /// At the start of a line under a list item, small models often drop the marker ("bread" after "- milk").
    /// Put it back, numbering on from the previous item.
    private static func continueList(_ reply: String, after prefix: String) -> String {
        let lines = prefix.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard let prev = lines.last else { return reply }
        let indent = String(prev.prefix { $0 == " " || $0 == "\t" })
        let body = prev.dropFirst(indent.count)
        var marker: String?
        for m in ["- ", "* ", "• ", "– "] where body.hasPrefix(m) { marker = m }
        if marker == nil, let dot = body.firstIndex(where: { $0 == "." || $0 == ")" }),
           let n = Int(body[..<dot]), body[body.index(after: dot)...].hasPrefix(" ") {
            marker = "\(n + 1)\(body[dot]) "
        }
        guard let marker else { return reply }
        let markerKind = marker.trimmingCharacters(in: .whitespaces)
        if reply.hasPrefix(markerKind) || reply.first.map({ "-*•–".contains($0) || $0.isNumber }) == true { return indent + reply }
        return indent + marker + reply
    }


    /// Small models sometimes repeat the end of a partial word ("timel" → "eline" for "timeline").
    /// If dropping the repeated letters turns the join into a real word (and the plain join isn't one), drop them.
    private static func repairOverlap(_ prefix: String, _ reply: String) -> String {
        let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let head = String(reply.prefix { $0.isLetter })
        guard tail.count >= 2, !head.isEmpty, !Spelling.isWord(tail + head, in: prefix) else { return reply }
        for k in stride(from: min(tail.count, head.count), through: 1, by: -1)
        where tail.suffix(k).lowercased() == head.prefix(k).lowercased() && Spelling.isWord(tail + head.dropFirst(k), in: prefix) {
            return String(reply.dropFirst(k))
        }
        return reply
    }

    /// The model sometimes skips a half-typed word and starts a new one ("I really apprec" → "your help"), and
    /// gluing them gives "apprecyour help". Finish the word from the dictionary instead ("iate your help"); if the
    /// reply is garbled too, or no dictionary word fits, return "" so nothing is shown.
    private static func completeIgnoredWord(_ prefix: String, _ reply: String) -> String? {
        let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let head = String(reply.prefix { $0.isLetter })
        guard fragment(prefix) == tail, !head.isEmpty, !Spelling.isWord(tail + head, in: prefix) else { return nil }
        guard Spelling.isWord(head, in: prefix) else { return "" }   // neither finishes the word nor makes sense on its own
        guard let word = Spelling.completion(of: tail, in: prefix) else { return "" }
        return String(word.dropFirst(tail.count)) + " " + reply
    }

    /// True when the reply continues the word the text ends in. Chat replies never start with the joining space, so
    /// when the text ends in a whole word ("con", "tar") the reply may finish it or start a new one: it finishes it
    /// when the two together make a word ("con" + "firmar", "the" + "re"). A reply starting with a short word of its
    /// own is the exception: joining then needs the joined word to be one of the most common completions in the
    /// text's language, so "tar" + "de" is "tarde" (its first completion) but "in" + "to the store" stays two words.
    private static func finishesWord(_ prefix: String, _ reply: String) -> Bool {
        let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let head = String(reply.prefix { $0.isLetter })
        guard !tail.isEmpty, !head.isEmpty else { return false }
        if head.first?.isUppercase == true, tail.last?.isLowercase == true { return false }   // "update" + "Talk soon"
        if fragment(prefix) != nil { return true }   // half-typed (names and common words aren't)
        let joined = tail + head
        guard Spelling.isWord(joined, in: prefix) else { return false }
        guard Spelling.shortWords(for: prefix).contains(head.lowercased()) else { return true }
        let rank = Spelling.completions(of: tail, in: prefix).firstIndex { $0.caseInsensitiveCompare(joined) == .orderedSame }
        return rank.map { $0 < 8 } ?? false
    }

}

/// Dictionary checks in the user's own languages (e.g. English and Spanish).
/// A small thread-safe cache: each suggestion asks about the same text and words many times (on the main thread for
/// the typo check and hint, on the network thread for the join), and the same words again on the next keystroke.
final class Memo<Key: Hashable, Value> {
    private var store: [Key: Value] = [:]
    private let lock = NSLock()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func value(_ key: Key, _ make: () -> Value) -> Value {
        lock.lock()
        if let v = store[key] { lock.unlock(); return v }
        lock.unlock()
        let v = make()
        lock.lock()
        if store.count >= limit { store.removeAll(keepingCapacity: true) }
        store[key] = v
        lock.unlock()
        return v
    }
}

enum Spelling {
    private static let languageMemo = Memo<String, String?>(limit: 64)
    private static let wordMemo = Memo<String, Bool>(limit: 4000)
    private static let completionsMemo = Memo<String, [String]>(limit: 2000)

    /// Spell-checker languages matching the user's preferred languages (e.g. English and Spanish).
    static let languages: [String] = {
        let available = NSSpellChecker.shared.availableLanguages
        var out: [String] = []
        for pref in Locale.preferredLanguages {
            let base = String(pref.prefix { $0 != "-" && $0 != "_" })
            if let m = available.first(where: { $0 == pref }) ?? available.first(where: { $0 == base || $0.hasPrefix(base + "_") }),
               !out.contains(m) { out.append(m) }
        }
        return out.isEmpty ? ["en"] : out
    }()

    /// Short words that start a new word on their own, for the language the text is written in
    /// ("in" + "to the store" is two words in English; "se" is a word in Spanish but "plea" + "se" is "please").
    static func shortWords(for text: String) -> Set<String> {
        let en: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "at", "by", "for", "and", "or", "but", "so", "as", "if", "it",
                               "is", "be", "do", "go", "no", "up", "us", "we", "me", "my", "you", "he", "she", "they", "not", "all", "with"]
        let es: Set<String> = ["y", "e", "o", "u", "a", "de", "la", "el", "en", "un", "una", "que", "se", "lo", "le", "mi", "tu", "su",
                               "es", "al", "del", "con", "por", "no", "me", "te", "ya", "si"]
        switch language(of: text).map({ String($0.prefix(2)) }) {
        case "es"?: return es
        case "en"?: return en
        default: return en.union(es)
        }
    }

    /// The user's spell-checker language that `text` is clearly written in, if any.
    static func language(of text: String) -> String? {
        let text = String(text.suffix(300))
        return languageMemo.value(text) { detectLanguage(text) }
    }

    private static func detectLanguage(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        // Only the user's own languages: far more confident on short texts ("Nos vemos esta" is 51 % Spanish
        // unconstrained, 99.9 % among English and Spanish).
        r.languageConstraints = Array(Set(languages.map { NLLanguage(rawValue: String($0.prefix { $0 != "_" })) }))
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.6 else { return nil }
        return languages.first { $0 == lang.rawValue || $0.hasPrefix(lang.rawValue + "_") }
    }

    /// The user's languages, the one `text` is written in first ("confir" in Spanish → "confirmar", not "confirming").
    static func languages(for text: String?) -> [String] {
        guard let text, let l = language(of: text) else { return languages }
        return [l] + languages.filter { $0 != l }
    }

    /// Dictionary completions of a partial word, most common first, in the text's language (or the first one).
    static func completions(of partial: String, in text: String? = nil) -> [String] {
        completions(of: partial, language: languages(for: text).first)
    }

    private static func completions(of partial: String, language: String?) -> [String] {
        completionsMemo.value(partial + "|" + (language ?? "")) {
            let r = NSRange(location: 0, length: (partial as NSString).length)
            return NSSpellChecker.shared.completions(forPartialWordRange: r, in: partial, language: language, inSpellDocumentWithTag: 0) ?? []
        }
    }

    /// The dictionary's first completion of a partial word, trying the text's language first ("apprec" → "appreciate").
    static func completion(of partial: String, in text: String? = nil) -> String? {
        for lang in languages(for: text) {
            let list = completions(of: partial, language: lang)
            if let w = list.first(where: { $0.lowercased().hasPrefix(partial.lowercased()) && $0.count > partial.count }) {
                // Keep the typed capitalization.
                return partial + w.dropFirst(partial.count)
            }
        }
        return nil
    }

    /// A word people commonly type on its own: the dictionary lists it among its own completions ("con" → "con,
    /// contenido…"), while a rare word that's usually the start of a longer one isn't ("tar" → "tarde, tarjeta…").
    static func isCommonWord(_ w: String, in text: String) -> Bool {
        guard isWord(w, in: text) else { return false }
        return completions(of: w, in: text).contains { $0.caseInsensitiveCompare(w) == .orderedSame }
    }

    /// A word in the text's language when that's clear, else in any of the user's languages.
    static func isWord(_ w: String, in text: String? = nil) -> Bool {
        let langs = text.flatMap(language(of:)).map { [$0] } ?? languages
        return langs.contains { lang in
            wordMemo.value(w + "|" + lang) {
                NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0,
                                                    wordCount: nil).location == NSNotFound
            }
        }
    }
}
