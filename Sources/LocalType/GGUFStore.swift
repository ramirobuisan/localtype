import Foundation

/// Local library of GGUF model files used by the embedded engine.
final class GGUFStore: NSObject, URLSessionDownloadDelegate {
    static let shared = GGUFStore()

    struct Entry { let file: String; let url: String; let note: String }
    static let catalog: [Entry] = [
        Entry(file: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
              url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
              note: "0.5 GB · fastest, rough"),
        Entry(file: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
              url: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
              note: "1.1 GB · fast"),
        Entry(file: "qwen2.5-3b-instruct-q4_k_m.gguf",
              url: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
              note: "2.1 GB · balanced (recommended)"),
        Entry(file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
              url: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
              note: "2.0 GB · balanced"),
        Entry(file: "gemma-3-4b-it-Q4_K_M.gguf",
              url: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
              note: "2.5 GB · best quality"),
    ]

    static var directory: URL {
        let dir = AppPaths.support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func path(for file: String) -> String { directory.appendingPathComponent(file).path }
    static var activePath: String? {
        let f = Settings.embeddedModel
        return !f.isEmpty && FileManager.default.fileExists(atPath: path(for: f)) ? path(for: f) : nil
    }

    func list() -> [InstalledModel] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: GGUFStore.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "gguf" }.map {
            InstalledModel(name: $0.lastPathComponent,
                           size: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }.sorted { $0.name < $1.name }
    }

    func delete(_ file: String) -> Bool {
        if file == Settings.embeddedModel { LlamaEngine.shared.unload() }
        return (try? FileManager.default.removeItem(atPath: GGUFStore.path(for: file))) != nil
    }

    func importFile(_ src: URL) -> String? {
        let dest = GGUFStore.directory.appendingPathComponent(src.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            return nil
        } catch { return error.localizedDescription }
    }

    // MARK: Download

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var target = ""
    private var onProgress: ((String, Double?) -> Void)?
    private var onDone: ((String?) -> Void)?
    var isBusy: Bool { task != nil }

    override init() {
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    }

    /// `idOrURL` is a catalog file name or a direct https URL to a .gguf file.
    func download(_ idOrURL: String, progress: @escaping (String, Double?) -> Void, done: @escaping (String?) -> Void) {
        guard task == nil else { return done("A download is already running") }
        let urlString = GGUFStore.catalog.first { $0.file == idOrURL }?.url ?? idOrURL
        guard let url = URL(string: urlString), url.scheme == "https", url.pathExtension.lowercased() == "gguf" else {
            return done("Enter a catalog model or an https URL ending in .gguf")
        }
        target = url.lastPathComponent
        onProgress = progress; onDone = done
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancelDownload() { task?.cancel() }

    private func finish(_ err: String?) {
        let cb = onDone
        task = nil; onProgress = nil; onDone = nil
        cb?(err)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData written: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        if total > 0 {
            let f = Double(totalBytesWritten) / Double(total)
            onProgress?("Downloading \(target) — \(fmt(totalBytesWritten)) of \(fmt(total))", f)
        } else {
            onProgress?("Downloading \(target) — \(fmt(totalBytesWritten))", nil)
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            return finish("Server returned HTTP \(http.statusCode)")
        }
        let dest = GGUFStore.directory.appendingPathComponent(target)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            finish(nil)
        } catch { finish(error.localizedDescription) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error as NSError? else { return }   // success handled in didFinishDownloadingTo
        finish(e.code == NSURLErrorCancelled ? "Cancelled" : e.localizedDescription)
    }
}
