import Foundation

/// What the Models window needs from a model source (built-in GGUF library or Ollama).
protocol ModelStore: AnyObject {
    var catalog: [(id: String, note: String)] { get }
    var placeholder: String { get }
    var canImport: Bool { get }
    var canDownload: Bool { get }
    var canDelete: Bool { get }
    var isBusy: Bool { get }
    var activeName: String { get set }
    func prepare(_ done: @escaping (String?) -> Void)          // nil = ready, else message
    func list(_ done: @escaping ([InstalledModel]?) -> Void)
    func isActive(_ installed: String) -> Bool
    func download(_ id: String, progress: @escaping (String, Double?) -> Void, done: @escaping (String?) -> Void)
    func cancelDownload()
    func delete(_ name: String, _ done: @escaping (Bool) -> Void)
}

final class EmbeddedStore: ModelStore {
    static let shared = EmbeddedStore()
    var catalog: [(id: String, note: String)] { GGUFStore.catalog.map { ($0.file, $0.note) } }
    let placeholder = "Pick a model, or paste an https://…/model.gguf URL"
    let canImport = true
    let canDownload = true
    let canDelete = true
    var isBusy: Bool { GGUFStore.shared.isBusy }
    var activeName: String {
        get { Settings.embeddedModel }
        set { Settings.embeddedModel = newValue; if let p = GGUFStore.activePath { LlamaEngine.shared.preload(path: p) } }
    }
    func prepare(_ done: @escaping (String?) -> Void) { done(nil) }
    func list(_ done: @escaping ([InstalledModel]?) -> Void) { done(GGUFStore.shared.list()) }
    func isActive(_ installed: String) -> Bool { installed == Settings.embeddedModel }
    func download(_ id: String, progress: @escaping (String, Double?) -> Void, done: @escaping (String?) -> Void) {
        GGUFStore.shared.download(id, progress: progress, done: done)
    }
    func cancelDownload() { GGUFStore.shared.cancelDownload() }
    func delete(_ name: String, _ done: @escaping (Bool) -> Void) {
        let ok = GGUFStore.shared.delete(name)
        if ok, name == Settings.embeddedModel { Settings.embeddedModel = "" }
        done(ok)
    }
}

final class OllamaStore: ModelStore {
    static let shared = OllamaStore()
    var catalog: [(id: String, note: String)] { ModelManager.recommended.map { ($0.name, $0.note) } }
    let placeholder = "Pick or type a model, e.g. qwen2.5:3b"
    let canImport = false
    let canDownload = true
    let canDelete = true
    var isBusy: Bool { ModelManager.shared.pulling != nil }
    var activeName: String {
        get { Settings.model }
        set { Settings.model = newValue }
    }
    func prepare(_ done: @escaping (String?) -> Void) {
        ModelManager.shared.ensureServer { up in
            done(up ? nil : (ModelManager.ollamaBinary == nil
                ? "Ollama isn't installed. Install it with: brew install ollama"
                : "Couldn't start Ollama at \(Settings.endpoint)"))
        }
    }
    func list(_ done: @escaping ([InstalledModel]?) -> Void) { ModelManager.shared.list(done) }
    func isActive(_ installed: String) -> Bool { ModelManager.matches(installed, Settings.model) }
    func download(_ id: String, progress: @escaping (String, Double?) -> Void, done: @escaping (String?) -> Void) {
        ModelManager.shared.pull(id, progress: progress, done: done)
    }
    func cancelDownload() { ModelManager.shared.cancelPull() }
    func delete(_ name: String, _ done: @escaping (Bool) -> Void) { ModelManager.shared.delete(name, done) }
}

func currentStore() -> ModelStore {
    switch Settings.backend {
    case "embedded": return EmbeddedStore.shared
    case "mlxserve": return MLXServeStore.shared
    default: return OllamaStore.shared
    }
}
