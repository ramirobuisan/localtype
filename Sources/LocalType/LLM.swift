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
                completion(MLXServeCompletion.join(reply, after: prefix))
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
