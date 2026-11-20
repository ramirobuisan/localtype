import AppKit
import Vision

AppPaths.migrateLegacyData()

// Headless check of the embedded engine: LocalType --selftest <model.gguf> "<prompt>"
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--selftest" {
    let path = CommandLine.arguments[2], prompt = CommandLine.arguments[3]
    let sem = DispatchSemaphore(value: 0)
    for round in 1...2 {   // second round exercises the KV-cache reuse path
        let t0 = Date()
        LlamaEngine.shared.complete(path: path, prompt: prompt + (round == 2 ? " and" : ""), maxTokens: 24) { out in
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("round \(round) [\(ms) ms]: \(out.map { "\"\($0)\"" } ?? "nil")")
            sem.signal()
        }
        sem.wait()
    }
    LlamaEngine.shared.shutdown()
    exit(0)
}

// MLX-Serve check: LocalType --selftest-mlx "text one" "text two" … (uses the configured or a loaded model)
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest-mlx" {
    let texts = Array(CommandLine.arguments.dropFirst(2))
    let llm = LLM()
    Settings.backend = "mlxserve"
    func run(_ i: Int) {
        guard i < texts.count else { exit(0) }
        let t0 = Date()
        llm.complete(prefix: texts[i], appName: "Notes") { out in
            DispatchQueue.main.async {
                print("[\(Int(Date().timeIntervalSince(t0) * 1000)) ms] \(texts[i].debugDescription) + \(out.map { $0.debugDescription } ?? "nil")")
                run(i + 1)
            }
        }
    }
    MLXServeStore.shared.prepare { problem in
        if let problem { print(problem); exit(1) }
        MLXServeStore.shared.autoSelect { print("model: \(Settings.mlxModel)"); run(0) }
    }
    RunLoop.main.run()
}

// Emoji matcher check: LocalType --selftest-emoji "I love this :fir" ":thumbs_u" …
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest-emoji" {
    for text in CommandLine.arguments.dropFirst(2) {
        let q = Emoji.query(in: text)
        let hits = q.map { Emoji.search($0) } ?? []
        print("\(text.debugDescription) → query \(q.map { "\"\($0)\"" } ?? "nil"): " + hits.map { "\($0.char) \($0.name)" }.joined(separator: ", "))
    }
    exit(0)
}

// Screen context check: LocalType --selftest-screen <pid> — OCRs that app's front window (needs Screen Recording).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest-screen", let pid = pid_t(CommandLine.arguments[2]) {
    _ = NSApplication.shared   // ScreenCaptureKit needs a WindowServer connection
    print("Screen Recording permitted: \(ScreenContext.permitted)")
    var t0 = Date()
    print("OCR languages: \(ScreenContext.languages(supported: (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []))")
    var round = 1
    ScreenContext.shared.refreshIfStale(pid: pid, caret: CGPoint(x: -1, y: -1))
    func poll() {
        if let text = ScreenContext.shared.text(pid: pid, caret: ScreenContext.shared.lastFrameCenter ?? .zero, excluding: "") {
            print("round \(round) [\(Int(Date().timeIntervalSince(t0) * 1000)) ms] \(text.count) chars: \(text.prefix(200))")
            if round == 2 { exit(0) }
            // Second round: a warm capture, as during normal typing.
            round = 2; t0 = Date()
            ScreenContext.shared.clear()
            ScreenContext.shared.refreshIfStale(pid: pid, caret: CGPoint(x: -1, y: -1))
        }
        if Date().timeIntervalSince(t0) > 60 { print("no text captured"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
