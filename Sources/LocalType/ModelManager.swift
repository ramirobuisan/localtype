import AppKit

struct InstalledModel {
    let name: String
    let size: Int64
}

/// Manages models on the local Ollama server: list, download (with progress), delete, and starting the server.
final class ModelManager: NSObject, URLSessionDataDelegate {
    static let shared = ModelManager()

    static let recommended: [(name: String, note: String)] = [
        ("qwen2.5:0.5b", "~0.4 GB · fastest, rough"),
        ("qwen2.5:1.5b", "~1 GB · fast"),
        ("qwen2.5:3b", "~1.9 GB · balanced (default)"),
        ("llama3.2:3b", "~2 GB · balanced"),
        ("gemma3:4b", "~3.3 GB · best quality"),
    ]

    private var session: URLSession!
    private var pullTask: URLSessionDataTask?
    private var buffer = Data()
    private var onProgress: ((String, Double?) -> Void)?
    private var onDone: ((String?) -> Void)?
    private(set) var pulling: String?

    override init() {
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3600
        c.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }

    private func url(_ path: String) -> URL? { URL(string: Settings.endpoint + path) }

    // MARK: Server

    func ping(_ completion: @escaping (Bool) -> Void) {
        guard let u = url("/api/tags") else { return completion(false) }
        var r = URLRequest(url: u); r.timeoutInterval = 2
        URLSession.shared.dataTask(with: r) { _, resp, err in
            DispatchQueue.main.async { completion(err == nil && (resp as? HTTPURLResponse)?.statusCode == 200) }
        }.resume()
    }

    static var ollamaBinary: String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Makes sure a server is answering, starting `ollama serve` if it's installed but not running.
    func ensureServer(_ completion: @escaping (Bool) -> Void) {
        ping { [weak self] up in
            guard let self, !up else { return completion(true) }
            guard let bin = ModelManager.ollamaBinary else { return completion(false) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return completion(false) }
            self.waitForServer(tries: 20, completion)
        }
    }

    private func waitForServer(tries: Int, _ completion: @escaping (Bool) -> Void) {
        ping { [weak self] up in
            if up { completion(true) }
            else if tries <= 0 { completion(false) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.waitForServer(tries: tries - 1, completion) } }
        }
    }

    // MARK: Models

    func list(_ completion: @escaping ([InstalledModel]?) -> Void) {
        guard let u = url("/api/tags") else { return completion(nil) }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            var out: [InstalledModel]?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ms = obj["models"] as? [[String: Any]] {
                out = ms.compactMap { m in
                    guard let n = m["name"] as? String else { return nil }
                    return InstalledModel(name: n, size: (m["size"] as? NSNumber)?.int64Value ?? 0)
                }.sorted { $0.name < $1.name }
            }
            DispatchQueue.main.async { completion(out) }
        }.resume()
    }

    /// Ollama treats "qwen2.5:3b" and "qwen2.5:3b" the same; a bare name means ":latest".
    static func matches(_ installed: String, _ wanted: String) -> Bool {
        let w = wanted.contains(":") ? wanted : wanted + ":latest"
        return installed == w
    }

    func delete(_ name: String, _ completion: @escaping (Bool) -> Void) {
        guard let u = url("/api/delete") else { return completion(false) }
        var r = URLRequest(url: u)
        r.httpMethod = "DELETE"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name])
        URLSession.shared.dataTask(with: r) { _, resp, err in
            DispatchQueue.main.async { completion(err == nil && (resp as? HTTPURLResponse)?.statusCode == 200) }
        }.resume()
    }

    // MARK: Pull

    func pull(_ name: String, progress: @escaping (String, Double?) -> Void, done: @escaping (String?) -> Void) {
        guard pulling == nil, let u = url("/api/pull") else { return done("A download is already running") }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        pulling = name
        buffer = Data()
        onProgress = progress
        onDone = done
        pullTask = session.dataTask(with: r)
        pullTask?.resume()
    }

    func cancelPull() { pullTask?.cancel() }

    private func finish(_ error: String?) {
        let cb = onDone
        pulling = nil; pullTask = nil; onProgress = nil; onDone = nil; buffer = Data()
        cb?(error)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let err = obj["error"] as? String {
                dataTask.cancel(); finish(err); return
            }
            let status = obj["status"] as? String ?? ""
            var frac: Double?
            if let t = (obj["total"] as? NSNumber)?.doubleValue, t > 0,
               let c = (obj["completed"] as? NSNumber)?.doubleValue { frac = c / t }
            onProgress?(status, frac)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard pullTask === task || pulling != nil else { return }
        if let e = error as NSError?, e.code == NSURLErrorCancelled { finish("Cancelled") }
        else if let e = error { finish(e.localizedDescription) }
        else { finish(nil) }
    }
}
