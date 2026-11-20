import AppKit

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

/// Completion through MLX-Serve's chat endpoint. Instruct models degenerate on raw continuation
/// ("la la la…"), but follow a short "continue this text" instruction well.
enum MLXServeCompletion {
    static let system = """
        You are an autocomplete engine inside a text field. Continue the user's text from exactly where it stops. \
        Reply with only the next few words, never more than one sentence: no quotes, no explanations, no repeating the text. \
        If the text stops in the middle of a word, finish that word. Match the language, tone and formatting. \
        Lines in [brackets] at the top are context, not part of the text. \
        The text ends at the marker ‸, which is where the cursor is; write what comes right after it.
        """

    static func request(context: String, text: String, maxTokens: Int) -> URLRequest? {
        let model = Settings.batteryModelNow ?? Settings.mlxModel
        guard let u = URL(string: Settings.mlxEndpoint + "/v1/chat/completions"), !model.isEmpty else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": context + text + "‸"]],
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "top_p": 0.9,
            "stream": false,
            "stop": ["\n"],
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// The reply text, and whether it was cut off by the token limit.
    static func parse(_ data: Data) -> (text: String, cut: Bool)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let msg = (choice["message"] as? [String: Any])?["content"] as? String
        else { return nil }
        return (msg, choice["finish_reason"] as? String == "length")
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

        // Echo: the reply starts by repeating the last 2+ words of the text.
        let words = prefix.split(whereSeparator: \.isWhitespace)
        for k in stride(from: min(6, words.count), through: 2, by: -1) {
            let end = words.suffix(k).joined(separator: " ")
            if t.lowercased() == end.lowercased() { return "" }
            if t.lowercased().hasPrefix(end.lowercased() + " ") {
                t = String(t.dropFirst(end.count + 1))
                break
            }
        }
        guard let first = t.first, let last = prefix.last else { return t }
        if last == "\n" { return continueList(t, after: prefix) }
        if last.isWhitespace { return t }
        // Punctuation that attaches to the previous word.
        if ".,;:!?)]}…%".contains(first) || first == "'" || first == "’" { return t }
        if last.isLetter || last.isNumber {
            // Mid-word: the reply finishes the word ("I'll send the docum" + "ents").
            t = repairOverlap(prefix, t)
            return finishesWord(prefix, t) ? t : " " + t
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

    private static let shortWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "by", "for", "and", "or", "but", "so", "as", "if", "it", "is",
        "be", "do", "go", "no", "up", "us", "we", "me", "my", "you", "he", "she", "they", "not", "all", "with",
        "y", "e", "o", "u", "de", "la", "el", "en", "un", "una", "que", "se", "lo", "le", "mi", "tu", "su", "es", "al", "del", "con", "por",
    ]

    /// Small models sometimes repeat the end of a partial word ("timel" → "eline" for "timeline").
    /// If dropping the repeated letters turns the join into a real word (and the plain join isn't one), drop them.
    private static func repairOverlap(_ prefix: String, _ reply: String) -> String {
        let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let head = String(reply.prefix { $0.isLetter })
        guard tail.count >= 2, !head.isEmpty, !Spelling.isWord(tail + head) else { return reply }
        for k in stride(from: min(tail.count, head.count), through: 1, by: -1)
        where tail.suffix(k).lowercased() == head.prefix(k).lowercased() && Spelling.isWord(tail + head.dropFirst(k)) {
            return String(reply.dropFirst(k))
        }
        return reply
    }

    /// True when the reply continues the word the text ends in: that word isn't a word yet ("docum"),
    /// or the joined form is a normal completion of it ("rem" + "ind") and the reply doesn't simply start
    /// with a short word of its own ("in" + "to the store").
    private static func finishesWord(_ prefix: String, _ reply: String) -> Bool {
        let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let head = String(reply.prefix { $0.isLetter })
        guard !tail.isEmpty, !head.isEmpty else { return false }
        if !Spelling.isWord(tail) { return true }
        if shortWords.contains(head.lowercased()) { return false }
        let joined = tail + head
        guard Spelling.isWord(joined) else { return false }
        if !Spelling.isWord(head) { return true }
        let r = NSRange(location: 0, length: (tail as NSString).length)
        let completions = NSSpellChecker.shared.completions(forPartialWordRange: r, in: tail, language: nil, inSpellDocumentWithTag: 0) ?? []
        return completions.contains { $0.caseInsensitiveCompare(joined) == .orderedSame }
    }

}

/// Dictionary checks in the user's own languages (e.g. English and Spanish).
enum Spelling {
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

    /// A word in any of the user's languages.
    static func isWord(_ w: String) -> Bool {
        let sc = NSSpellChecker.shared
        return languages.contains { lang in
            sc.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}
