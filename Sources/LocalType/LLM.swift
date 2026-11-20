import AppKit

/// Gets suggestions from the chosen engine: MLX-Serve or Ollama through their chat endpoints (see ChatCompletion),
/// or the built-in llama.cpp engine, which continues the text directly.
final class LLM {
    private var task: URLSessionDataTask?
    private let session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return c
    }())

    /// LT_DEBUG=1 prints each request's context lines and the model's raw reply (development).
    static let debug = ProcessInfo.processInfo.environment["LT_DEBUG"] != nil

    func cancel() {
        task?.cancel(); task = nil
        LlamaEngine.shared.cancel()
    }

    /// A one-token request so the model is loaded before the first real suggestion (MLX-Serve can unload idle
    /// models; Ollama too). The built-in engine preloads separately.
    static func warmUp() {
        switch Settings.backend {
        case "mlxserve":
            if let r = ChatCompletion.request(context: "", text: "Hi", maxTokens: 1) { URLSession.shared.dataTask(with: r).resume() }
        case "ollama":
            guard let u = URL(string: Settings.endpoint + "/api/generate") else { return }
            var r = URLRequest(url: u); r.httpMethod = "POST"
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Settings.model, "prompt": "", "keep_alive": "30m"])
            URLSession.shared.dataTask(with: r).resume()
        default:
            if let p = GGUFStore.activePath { LlamaEngine.shared.preload(path: p) }
        }
    }

    // MARK: Lists (Labs: alternative words, synonyms)

    private var listTask: URLSessionDataTask?
    /// Lists need a chat model; the built-in engine only continues text.
    static var supportsLists: Bool { Settings.backend != "embedded" }

    func cancelList() { listTask?.cancel(); listTask = nil }

    /// Several short options from a chat model, one per line in its reply.
    func list(system: String, user: String, count: Int, completion: @escaping ([String]) -> Void) {
        cancelList()
        let messages = [["role": "system", "content": system], ["role": "user", "content": user]]
        let url: URL?, body: [String: Any]
        switch Settings.backend {
        case "mlxserve":
            url = URL(string: Settings.mlxEndpoint + "/v1/chat/completions")
            body = ["model": Settings.batteryModelNow ?? Settings.mlxModel, "messages": messages, "max_tokens": 80,
                    "temperature": 0.8, "stream": false, "chat_template_kwargs": ["enable_thinking": false]]
        case "ollama":
            url = URL(string: Settings.endpoint + "/api/chat")
            body = ["model": Settings.batteryModelNow ?? Settings.model, "messages": messages, "stream": false,
                    "options": ["temperature": 0.8, "num_predict": 80]]
        default:
            return completion([])
        }
        guard let url else { return completion([]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        listTask = session.dataTask(with: req) { data, _, error in
            guard error == nil, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return completion([]) }
            let text = (((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)
                ?? ((obj["message"] as? [String: Any])?["content"] as? String) ?? ""
            completion(LLM.parseList(text, count: count))
        }
        listTask?.resume()
    }

    /// One option per line; drops numbering, bullets, quotes, blanks and duplicates.
    static func parseList(_ text: String, count: Int) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: #"^(\d{1,2}[.)]|[-*•])\s+"#, options: .regularExpression) { line.removeSubrange(r) }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’`‸"))
            guard !line.isEmpty, line.count <= 40, seen.insert(line.lowercased()).inserted else { continue }
            out.append(line)
            if out.count == count { break }
        }
        return out
    }

    func complete(prefix: String, appName: String?, screen: String? = nil, completion: @escaping (String?) -> Void) {
        cancel()
        // Context goes in as short bracketed lines before the text (the chat prompt explains them; the built-in engine's
        // raw mode reads them as-is). Ordered from most to least stable so the engine can reuse its cache across keystrokes.
        // The person's style is part of the chat instructions (ChatCompletion.messages): as a line before the text,
        // models took "keep your sentences short" as an order to rewrite the text.
        var header = ""
        if let appName { header += "[Writing in \(appName)]\n" }
        if let screen, !screen.isEmpty { header += "[On screen: \(screen)]\n" }
        if Settings.useClipboard, let clip = NSPasteboard.general.string(forType: .string) {
            let c = clip.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            if !c.isEmpty { header += "[Clipboard: \(c.prefix(400))]\n" }
        }
        if Settings.recordWriting {
            let n = Int((Settings.personalization * 4).rounded())
            let ex = History.shared.relevant(to: prefix, limit: n)
            if !ex.isEmpty { header += "[The user's own phrasing: " + ex.map { "\"\($0)\"" }.joined(separator: " ") + "]\n" }
        }
        if Settings.backend == "embedded" {
            let battery = Settings.batteryModelNow.map(GGUFStore.path(for:)).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            guard let path = battery ?? GGUFStore.activePath else { return completion(nil) }
            let style = Settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawHeader = (style.isEmpty ? "" : "[Style: \(style.replacingOccurrences(of: "\n", with: " "))]\n") + header
            let raw = rawHeader.isEmpty ? prefix : rawHeader + "\n" + prefix
            embedded(path: path, context: chatContext(header, prefix), raw: raw, prefix: prefix, maxTokens: Settings.effectiveMaxTokens,
                     completion: completion)
            return
        }
        chat(context: chatContext(header, prefix), prefix: prefix, completion: completion)
    }

    /// Chat models also get the words a half-typed word may become (last: it changes with every keystroke).
    private func chatContext(_ header: String, _ prefix: String) -> String {
        let h = header + (ChatCompletion.unfinishedWordHint(prefix) ?? "")
        return h.isEmpty ? "" : h + "\n"
    }

    /// MLX-Serve and Ollama: the chat prompt, then the reply re-joined to the text and checked.
    /// The model repeated the text before going on and ran out of room ("…los detalles. ¿Te"): worth one more request
    /// with room for the repeat. Only the first request (at the normal length) is retried.
    private static func needsRoom(_ reply: String, cut: Bool, prefix: String, maxTokens: Int) -> Bool {
        cut && maxTokens == Settings.effectiveMaxTokens && ChatCompletion.stripEcho(reply, prefix: prefix) != nil
    }

    private func embedded(path: String, context: String, raw: String, prefix: String, maxTokens: Int,
                          completion: @escaping (String?) -> Void) {
        LlamaEngine.shared.complete(path: path, messages: ChatCompletion.messages(context: context, text: prefix), raw: raw,
                                    maxTokens: maxTokens) { [self] text, cut, chat in
            guard let text else { return completion(nil) }
            // A model without a chat format continued the text itself: nothing to re-join or check.
            guard chat else { return completion(text) }
            if LLM.needsRoom(text, cut: cut, prefix: prefix, maxTokens: maxTokens) {
                return DispatchQueue.main.async {
                    self.embedded(path: path, context: context, raw: raw, prefix: prefix, maxTokens: maxTokens * 3, completion: completion)
                }
            }
            completion(ChatCompletion.finish(text, cut: cut, context: context, prefix: prefix))
        }
    }

    private func chat(context: String, prefix: String, retry: Bool = true, maxTokens: Int = Settings.effectiveMaxTokens,
                      completion: @escaping (String?) -> Void) {
        guard let req = ChatCompletion.request(context: context, text: prefix, maxTokens: maxTokens) else {
            return completion(nil)
        }
        // Strong capture: the retry below must run (and call back) even if the caller let go of this LLM.
        task = session.dataTask(with: req) { [self] data, _, error in
            guard error == nil, let data else { return completion(nil) }
            guard let reply = ChatCompletion.parse(data) else {
                // Older Ollama versions and some models refuse the "don't think" switch: ask once more without it.
                if retry, Settings.backend == "ollama", !ChatCompletion.ollamaRejectsThink,
                   String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("think") {
                    ChatCompletion.ollamaRejectsThink = true
                    return DispatchQueue.main.async { self.chat(context: context, prefix: prefix, retry: false, completion: completion) }
                }
                return completion(nil)
            }
            if LLM.needsRoom(reply.text, cut: reply.cut, prefix: prefix, maxTokens: maxTokens) {
                if LLM.debug { FileHandle.standardError.write(Data("── repeat cut short: \(reply.text.debugDescription), asking again\n".utf8)) }
                return DispatchQueue.main.async {
                    self.chat(context: context, prefix: prefix, retry: retry, maxTokens: maxTokens * 3, completion: completion)
                }
            }
            let out = ChatCompletion.finish(reply.text, cut: reply.cut, context: context, prefix: prefix)
            if LLM.debug { FileHandle.standardError.write(Data("── context\n\(context)── raw \(reply.text.debugDescription) → \(out.debugDescription)\n".utf8)) }
            completion(out)
        }
        task?.resume()
    }
}
