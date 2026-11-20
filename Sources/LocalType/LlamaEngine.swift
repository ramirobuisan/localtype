import Foundation
import llama

/// In-process llama.cpp inference (Metal). One model loaded at a time; the KV cache is reused
/// across keystrokes when the new prompt shares a prefix with the previous one.
final class LlamaEngine {
    static let shared = LlamaEngine()

    private let queue = DispatchQueue(label: "localtype.llama", qos: .userInitiated)
    private let onQueue = DispatchSpecificKey<Bool>()
    private init() { queue.setSpecific(key: onQueue, value: true) }
    private let lock = NSLock()
    private var latest = 0

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedPath: String?
    private var cached: [llama_token] = []
    private var backendReady = false

    // Room for the chat prompt (instructions and examples, ~700 tokens) plus context lines and 1,500 characters of text.
    private static var exitHookSet = false
    private static let nCtx: UInt32 = 4096
    private static let maxPromptTokens = 3500

    private func bump() -> Int { lock.lock(); defer { lock.unlock() }; latest += 1; return latest }
    private func isCurrent(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return g == latest }
    func cancel() { _ = bump() }

    /// Loads the model in the background so the first suggestion isn't slow.
    func preload(path: String) {
        queue.async { _ = self.ensureLoaded(path) }
    }

    func unload() {
        _ = bump()
        queue.async { self.freeModel() }
    }

    /// Frees Metal resources synchronously; must run before process exit or ggml aborts in its static destructors.
    /// Safe to call more than once and from the engine's own queue (an exit inside a completion callback).
    func shutdown() {
        _ = bump()
        let work = {
            self.freeModel()
            if self.backendReady { llama_backend_free(); self.backendReady = false }
        }
        if DispatchQueue.getSpecific(key: onQueue) == true { work() } else { queue.sync(execute: work) }
    }

    func complete(path: String, prompt: String, maxTokens: Int, completion: @escaping (String?) -> Void) {
        let gen = bump()
        queue.async {
            guard self.isCurrent(gen) else { return completion(nil) }
            guard self.ensureLoaded(path) else { return completion(nil) }
            completion(self.generate(prompt: prompt, special: false, maxTokens: maxTokens, gen: gen)?.text)
        }
    }

    /// Chat models get `messages` in the model's own chat format (the template stored in the model file), like
    /// MLX-Serve and Ollama do; models without one (base models) get `raw`, plain text to continue. Calls back with
    /// the reply, whether the token limit cut it, and whether the chat format was used.
    func complete(path: String, messages: [[String: String]], raw: String, maxTokens: Int,
                  completion: @escaping (_ text: String?, _ cut: Bool, _ chat: Bool) -> Void) {
        let gen = bump()
        queue.async {
            guard self.isCurrent(gen), self.ensureLoaded(path) else { return completion(nil, false, false) }
            if let prompt = self.chatPrompt(messages) {
                let r = self.generate(prompt: prompt, special: true, maxTokens: maxTokens, gen: gen)
                completion(r?.text, r?.cut ?? false, true)
            } else {
                let r = self.generate(prompt: raw, special: false, maxTokens: maxTokens, gen: gen)
                completion(r?.text, r?.cut ?? false, false)
            }
        }
    }

    /// The conversation in the model's chat format, ending where the assistant's reply starts; nil without a template.
    private func chatPrompt(_ messages: [[String: String]]) -> String? {
        guard let model, let tmpl = llama_model_chat_template(model, nil) else { return nil }
        let roles = messages.map { strdup($0["role"] ?? "user") }
        let contents = messages.map { strdup($0["content"] ?? "") }
        defer { (roles + contents).forEach { free($0) } }
        var chat = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        var buf = [CChar](repeating: 0, count: 16384)
        var n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
        }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Internals (queue-confined)

    private func freeModel() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil; loadedPath = nil; cached = []
    }

    private func ensureLoaded(_ path: String) -> Bool {
        if loadedPath == path, ctx != nil { return true }
        freeModel()
        if !backendReady {
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
            backendReady = true
        }
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(path, mp) else { return false }
        var cp = llama_context_default_params()
        cp.n_ctx = LlamaEngine.nCtx
        cp.n_batch = 512
        let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); return false }
        model = m; ctx = c; vocab = llama_model_get_vocab(m); loadedPath = path; cached = []
        // Free the GPU resources on any exit, before ggml's own cleanup (registered while loading, so it runs after
        // this): it aborts if they're still held. Quitting the app frees them earlier; this covers direct exits.
        if !LlamaEngine.exitHookSet {
            LlamaEngine.exitHookSet = true
            atexit { LlamaEngine.shared.shutdown() }
        }
        return true
    }

    /// `special`: read the chat format's markers (<|im_start|> …) as the model's control tokens, not as text.
    private func tokenize(_ text: String, special: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8 = Array(text.utf8)
        var out = [llama_token](repeating: 0, count: utf8.count + 8)
        var n = llama_tokenize(vocab, text, Int32(utf8.count), &out, Int32(out.count), true, special)
        if n < 0 {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(utf8.count), &out, Int32(out.count), true, special)
        }
        return n > 0 ? Array(out.prefix(Int(n))) : []
    }

    private func decode(_ tokens: [llama_token]) -> Bool {
        guard let ctx else { return false }
        var i = 0
        while i < tokens.count {
            var chunk = Array(tokens[i..<min(i + 512, tokens.count)])
            i += chunk.count
            let rc = chunk.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
            }
            if rc != 0 { return false }
        }
        return true
    }

    private func resetCache() {
        if let ctx { llama_memory_clear(llama_get_memory(ctx), true) }
        cached = []
    }

    private func generate(prompt: String, special: Bool, maxTokens: Int, gen: Int) -> (text: String, cut: Bool)? {
        guard let ctx, let vocab else { return nil }
        var tokens = tokenize(prompt, special: special)
        guard !tokens.isEmpty else { return nil }
        if tokens.count > LlamaEngine.maxPromptTokens {
            // Raw text can lose its start; a chat prompt can't (its instructions are at the start).
            guard !special else { return nil }
            tokens = Array(tokens.suffix(LlamaEngine.maxPromptTokens))
        }

        // Reuse KV cache for the shared prefix; always re-decode at least the last token.
        var common = 0
        while common < min(cached.count, tokens.count), cached[common] == tokens[common] { common += 1 }
        if common == tokens.count { common -= 1 }
        if common <= 0 {
            resetCache(); common = 0
        } else if !llama_memory_seq_rm(llama_get_memory(ctx), 0, Int32(common), -1) {
            resetCache(); common = 0
        }
        cached = tokens

        guard decode(Array(tokens[common...])) else { resetCache(); return nil }
        guard isCurrent(gen) else { return nil }

        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.2))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        var bytes: [UInt8] = []
        var buf = [CChar](repeating: 0, count: 128)
        var cut = true
        for _ in 0..<maxTokens {
            guard isCurrent(gen) else { return nil }
            let id = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, id) { cut = false; break }
            let n = llama_token_to_piece(vocab, id, &buf, Int32(buf.count), 0, false)
            if n > 0 { bytes.append(contentsOf: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }) }
            if bytes.contains(10) || bytes.contains(13) { cut = false; break }
            var one = [id]
            let rc = one.withUnsafeMutableBufferPointer { b in
                llama_decode(ctx, llama_batch_get_one(b.baseAddress, 1))
            }
            if rc != 0 { resetCache(); break }
        }
        var s = String(decoding: bytes, as: UTF8.self)
        while s.last == "\u{FFFD}" { s.removeLast() }   // cut mid-character by the token limit
        if let nl = s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) { s = String(s[..<nl]) }
        return (s, cut)
    }
}
