import AppKit

/// Talks to a local Ollama server. Raw mode = plain text continuation, no chat template.
final class LLM {
    private var task: URLSessionDataTask?
    private let session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return c
    }())

    func cancel() {
        task?.cancel(); task = nil
        LlamaEngine.shared.cancel()
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
        // Raw mode has no system prompt, so style/context goes in as a short bracketed header.
        // Ordered from most to least stable so the engine can reuse its KV cache across keystrokes.
        var header = ""
        let style = Settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty { header += "[Style: \(style.replacingOccurrences(of: "\n", with: " "))]\n" }
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
        if !header.isEmpty { header += "\n" }

        if Settings.backend == "mlxserve" {
            guard let req = MLXServeCompletion.request(context: header, text: prefix, maxTokens: Settings.effectiveMaxTokens) else {
                return completion(nil)
            }
            task = session.dataTask(with: req) { data, _, error in
                guard error == nil, let data, let reply = MLXServeCompletion.parse(data) else { return completion(nil) }
                completion(MLXServeCompletion.join(reply.text, after: prefix, cut: reply.cut))
            }
            task?.resume()
            return
        }

        if Settings.backend == "embedded" {
            let battery = Settings.batteryModelNow.map(GGUFStore.path(for:)).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            guard let path = battery ?? GGUFStore.activePath else { return completion(nil) }
            LlamaEngine.shared.complete(path: path, prompt: header + prefix, maxTokens: Settings.effectiveMaxTokens, completion: completion)
            return
        }

        guard let url = URL(string: Settings.endpoint + "/api/generate") else { return completion(nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": Settings.batteryModelNow ?? Settings.model,
            "prompt": header + prefix,
            "raw": true,
            "stream": false,
            "keep_alive": "30m",
            "options": [
                "num_predict": Settings.effectiveMaxTokens,
                "temperature": 0.2,
                "top_p": 0.9,
                "stop": ["\n", "\r"],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        task = session.dataTask(with: req) { data, _, error in
            guard error == nil, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["response"] as? String else { return completion(nil) }
            completion(text)
        }
        task?.resume()
    }
}
