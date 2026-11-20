import AppKit
import NaturalLanguage
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
    // Texts to complete; "-mlxModel <id>" (argument-domain default) picks a model without saving it.
    var texts: [String] = []
    var args = Array(CommandLine.arguments.dropFirst(2))
    while !args.isEmpty {
        let a = args.removeFirst()
        if a.hasPrefix("-"), !a.hasPrefix("--"), !args.isEmpty { args.removeFirst() } else { texts.append(a) }
    }
    let llm = LLM()
    if UserDefaults.standard.string(forKey: "backend") != "mlxserve" { Settings.backend = "mlxserve" }
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

// Field check: LocalType --selftest-field <bundle ID> — reads that app's focused field the way a suggestion would
// (works with the app in the background), then asks the model for a suggestion.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest-field" {
    _ = NSApplication.shared
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[2]).first,
          let el = AX.focusedElement(ofApp: app.processIdentifier) else { print("no focused element"); exit(1) }
    guard let ctx = AX.readContext(element: el) else {
        print("readContext: nil — LocalType would not suggest here (see a field probe for which check fails)"); exit(1)
    }
    print("prefix: …\(ctx.prefix.suffix(50).debugDescription) (\(ctx.prefix.count) chars)")
    print("caret: \(ctx.caretRect) line height \(ctx.lineHeight)")
    print("font: \(ctx.style.map { "\($0.font.fontName) \($0.font.pointSize)" } ?? "unknown (system font fallback)")")
    print("domain: \(ctx.domain ?? "none") · prompt place: \(ctx.place ?? "none")")
    let t0 = Date()
    MLXServeStore.shared.prepare { _ in
        LLM().complete(prefix: ctx.prefix, appName: ctx.place) { out in
            print("suggestion [\(Int(Date().timeIntervalSince(t0) * 1000)) ms]: \(out.map { $0.debugDescription } ?? "nil")")
            exit(0)
        }
    }
    RunLoop.main.run()
}

// Sync check: LocalType --selftest-sync — two simulated Macs in a scratch folder (run with LOCALTYPE_SUPPORT_DIR set).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-sync" {
    guard ProcessInfo.processInfo.environment["LOCALTYPE_SUPPORT_DIR"] != nil else { print("set LOCALTYPE_SUPPORT_DIR"); exit(2) }
    let cloud = AppPaths.support.appendingPathComponent("icloud", isDirectory: true)
    Sync.override = cloud
    try? FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    var ok = true
    func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); ok = ok && cond }
    let t0 = Date()
    let key = Sync.deriveKey("correct horse battery")!
    check("key derivation is deterministic (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)", Sync.deriveKey("correct horse battery")! == key)
    History.shared.add("This sentence was written on Mac A and stays.", app: "com.apple.TextEdit")
    History.shared.add("This one from Mac A gets deleted on Mac B later.", app: "com.apple.TextEdit")
    let doomed = History.fingerprint("This one from Mac A gets deleted on Mac B later.")
    // Mac B: one new sentence, and a deletion of A's second sentence.
    let b = History.Store(entries: [.init(text: "A sentence that was typed on Mac B instead.", date: Date(), app: "com.tinyspeck.slackmacgap")],
                          deleted: [doomed: Date().addingTimeInterval(60)])
    try? Vault.seal(try! JSONEncoder().encode(b), with: key)!.write(to: cloud.appendingPathComponent("history-macb.lthist"))
    // Mac C uses another passphrase: must be skipped and reported, not crash or corrupt anything.
    let c = History.Store(entries: [.init(text: "Mac C has a different passphrase entirely.", date: Date(), app: nil)], deleted: [:])
    try? Vault.seal(try! JSONEncoder().encode(c), with: Sync.deriveKey("another passphrase")!)!.write(to: cloud.appendingPathComponent("history-macc.lthist"))
    let result = Sync.run(key: key)
    if case .failed(let why) = result { print("result: \(why)") } else { print("result: \(result)") }
    let texts = Set(History.shared.entries.map(\.text))
    check("kept local sentence", texts.contains("This sentence was written on Mac A and stays."))
    check("merged Mac B's sentence", texts.contains("A sentence that was typed on Mac B instead."))
    check("applied Mac B's deletion", !texts.contains("This one from Mac A gets deleted on Mac B later."))
    check("skipped the other passphrase", !texts.contains("Mac C has a different passphrase entirely."))
    if case .failed(let why) = result { check("reported the other passphrase", why.contains("different sync passphrase")) } else { check("reported the other passphrase", false) }
    let mine = cloud.appendingPathComponent("history-\(Sync.deviceID).lthist")
    let raw = (try? Data(contentsOf: mine)) ?? Data()
    check("own file is encrypted (no plain text inside)", !raw.isEmpty && !(String(decoding: raw, as: UTF8.self).contains("Mac A")))
    let back = Vault.open(raw, with: key).flatMap { try? JSONDecoder().decode(History.Store.self, from: $0) }
    check("own file decrypts with the key and carries the deletion", back?.deleted[doomed] != nil && back?.entries.count == 2)
    let local = (try? Data(contentsOf: AppPaths.support.appendingPathComponent("history.enc"))) ?? Data()
    check("local history file is encrypted", !local.isEmpty && !String(decoding: local, as: UTF8.self).contains("Mac B"))
    print(ok ? "ALL PASSED" : "SOME FAILED")
    exit(ok ? 0 : 1)
}

// Labs check: LocalType --selftest-labs — alternatives and synonyms from the configured chat model.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-labs" {
    let llm = LLM()
    MLXServeStore.shared.prepare { _ in
        let prefix = "Thanks for the update. I think we should"
        llm.list(system: Controller.alternativesPrompt, user: "[Writing in Mail]\n\n" + prefix + "‸", count: 5) { alts in
            print("alternatives after \"\(prefix)\": " + alts.map { ChatCompletion.join(Controller.continuingCase($0, after: prefix), after: prefix).debugDescription }.joined(separator: ", "))
            print("case: \(Controller.continuingCase("Moving forward", after: "we should")) / \(Controller.continuingCase("I agree", after: "and")) / \(Controller.continuingCase("Laura said", after: "and")) / \(Controller.continuingCase("Great idea", after: "Done."))")
            let user = "Passage: …The results were «good», but the second test took much longer than expected.…\n\nReplace: good"
            llm.list(system: Controller.synonymsPrompt, user: user, count: 5) { syns in
                print("synonyms for «good»: " + syns.joined(separator: ", "))
                print("case matching: \(Controller.matchCase("excellent", to: "Good")) / \(Controller.matchCase("great", to: "GOOD"))")
                exit(0)
            }
        }
    }
    RunLoop.main.run()
}

// Update check: LocalType --selftest-update
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-update" {
    print("current: \(Updates.current); 0.10.0 > 0.9.2: \(Updates.isNewer("0.10.0", than: "0.9.2")); 0.3.0 > 0.3.0: \(Updates.isNewer("0.3.0", than: "0.3.0"))")
    Updates.check { outcome in print("check: \(outcome)"); exit(0) }
    RunLoop.main.run()
}

// Practice box check: LocalType --selftest-practice — reads a "Try it" text view directly (no Accessibility).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-practice" {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
    tv.identifier = AX.practiceID
    tv.font = .systemFont(ofSize: 14)
    tv.string = "Thanks for the update, I'll"
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    w.contentView = tv
    w.orderFront(nil)
    let other = NSTextView(); other.string = "Not the practice box"
    print("other text view ignored: \(AX.ownContext(other) == nil)")
    let t0 = Date()
    guard let ctx = AX.ownContext(tv) else { print("practice context: nil"); exit(1) }
    print("practice context in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: prefix \(ctx.prefix.debugDescription), caret \(ctx.caretRect), font \(ctx.style?.font.pointSize ?? 0), isPractice \(ctx.isPractice)")
    MLXServeStore.shared.prepare { _ in
        LLM().complete(prefix: ctx.prefix, appName: ctx.place) { out in print("suggestion: \(out.map { $0.debugDescription } ?? "nil")"); exit(0) }
    }
    RunLoop.main.run()
}

// Prompt check: LocalType --selftest-prompts — typing situations through the real completion path, with checks for
// the usual failures (placeholders, echoes, copied style text, wrong language, invented figures, broken lists or
// half-typed words, ignoring the screen, rambling). Use it to compare prompt changes.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-prompts" {
    // (app, text before the cursor, on-screen text, checks)
    let cases: [(String, String, String?, [String])] = [
        ("Mail", "Hi Laura,\n\nThanks for sending the slides over. I had a quick look and", nil, ["en"]),
        ("Mail", "Thanks again for your help with the slides.\n\nBest regards,\n", nil, ["name"]),
        ("WhatsApp", "Hola! Mañana no puedo ir a clase porque", nil, ["es"]),
        ("Mail", "Buenos días Marta,\n\nTe escribo para", nil, ["es"]),
        ("Mail", "Muchas gracias por todo.\n\nUn saludo,\n", nil, ["name"]),
        ("Notes", "I'll send you the docum", nil, ["word"]),
        ("Notes", "Nos vemos mañana en la universi", nil, ["word"]),
        ("Mail", "Thanks, I really apprec", nil, ["word"]),
        ("Mail", "Could you plea", nil, ["word"]),
        ("Mail", "I'm looking forw", nil, ["word", "starts:ard"]),
        ("Notes", "Shopping list:\n- eggs\n- milk\n", nil, ["list:- "]),
        ("Notes", "Steps:\n1. Open the app\n2. Click Settings\n", nil, ["list:3. "]),
        ("Slack", "lol yeah that meeting was", nil, ["en"]),
        ("Pages", "Dear Hiring Manager,\n\nI am writing to apply for the", nil, ["en"]),
        ("Messages", "Do you know if the train to Madrid", nil, ["en", "starts: "]),
        ("Messages", "Running a bit late, sorry! I'll be there", nil, ["en"]),
        ("Mail", "Quick update on the project: our total revenue last quarter was", nil, ["nofigures"]),
        ("Mail", "Te mando el informe por email y", nil, ["es"]),
        ("Mail", "Hi Laura,\n\nSure! I'll send you the", "Laura: Could you send me the Q3 budget numbers before Friday's board meeting?", ["screen:Q3|budget"]),
        ("Mail", "Thanks for the update. ", nil, ["en"]),
        ("Messages", "ok sounds good, see you", nil, ["en"]),
        ("Mail", "Hi Tom,\n\n", nil, ["en"]),
        ("Slack", "Thanks for the update, I'll", nil, ["en", "starts: "]),
        ("Google Chrome on github.com", "Thanks for the PR! The changes look good, but could you", nil, ["en"]),
        ("Safari on mail.google.com", "Hola Pablo,\n\nTe adjunto", nil, ["es"]),
        ("Google Chrome on reddit.com", "hole", nil, ["noassistant"]),
        ("Notes", "banana", nil, ["noassistant"]),
        ("WhatsApp", "Te llamo esta tar", nil, ["starts:de"]),
        ("Messages", "Nos vemos esta tar", nil, ["starts:de"]),
        ("Mail", "Mañana tengo la reu", nil, ["starts:ni"]),
        ("Mail", "Thanks for the quick repl", nil, ["starts:y"]),
    ]
    let style = Settings.instructions
    let name = style.range(of: #"(?i)my name is ([A-ZÁÉÍÓÚÑ][\p{L}]+)"#, options: .regularExpression)
        .map { String(style[$0]).split(separator: " ").last.map(String.init) ?? "" }
    func lang(_ s: String) -> NLLanguage? {
        let r = NLLanguageRecognizer(); r.languageConstraints = [.english, .spanish]; r.processString(s); return r.dominantLanguage
    }
    func issues(_ c: (String, String, String?, [String]), _ out: String?) -> [String] {
        guard let s = out else { return ["no reply"] }
        let t = s.trimmingCharacters(in: .whitespaces)
        var bad: [String] = []
        if t.range(of: #"[\[\]<>]"#, options: .regularExpression) != nil { bad.append("placeholder") }
        if !style.isEmpty, t.range(of: #"(?i)my name is|i usually write"#, options: .regularExpression) != nil { bad.append("copied style") }
        if t.split(separator: " ").count > 14 { bad.append("too long") }
        for k in c.3 {
            switch k {
            case "en": if t.split(separator: " ").count >= 3, lang(t) == .spanish { bad.append("not English") }
            case "es": if t.split(separator: " ").count >= 3, lang(t) == .english { bad.append("not Spanish") }
            case "name": if let n = name, !t.contains(n) { bad.append("no name") }
            case "word":
                let tail = String(c.1.reversed().prefix { $0.isLetter }.reversed())
                let head = String(s.prefix { $0.isLetter })
                if s.hasPrefix(" ") || head.isEmpty || !Spelling.isWord(tail + head) { bad.append("half-typed word not finished") }
            case "nofigures": if t.range(of: #"[$€£%]|\d{3,}"#, options: .regularExpression) != nil { bad.append("invented figure") }
            case "noassistant":
                if ChatCompletion.dropAssistantReply(t, prefix: c.1).isEmpty || t.range(of: #"(?i)^(sure|here|i'm|i am|sorry|could you|can you|what)\b"#, options: .regularExpression) != nil {
                    bad.append("talks to the user")
                }
            default:
                if k.hasPrefix("starts:"), !s.hasPrefix(String(k.dropFirst(7))) { bad.append("wrong word (want \(k.dropFirst(7))…)") }
                if k.hasPrefix("list:"), !t.hasPrefix(String(k.dropFirst(5))) { bad.append("list marker") }
                if k.hasPrefix("screen:"), t.range(of: String(k.dropFirst(7)), options: [.regularExpression, .caseInsensitive]) == nil { bad.append("ignored screen") }
            }
        }
        return bad
    }
    var clean = 0, empty = 0
    func run(_ i: Int) {
        guard i < cases.count else {
            // Showing nothing is a miss, not a wrong suggestion: counted apart.
            print("\n\(clean)/\(cases.count) clean" + (empty > 0 ? ", \(empty) without a suggestion, \(cases.count - clean - empty) wrong" : ""))
            exit(clean + empty == cases.count ? 0 : 1)
        }
        let c = cases[i]
        LLM().complete(prefix: c.1, appName: c.0, screen: c.2) { out in
            DispatchQueue.main.async {
                let none = out.map { $0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
                let bad = none ? [] : issues(c, out)
                if none { empty += 1 } else if bad.isEmpty { clean += 1 }
                let shown = c.1.replacingOccurrences(of: "\n", with: "⏎").suffix(42)
                print("\(none ? "·" : bad.isEmpty ? "✓" : "✗") …\(shown) + \((out ?? "nil").debugDescription.prefix(64))  \(none ? "no suggestion" : bad.joined(separator: ", "))")
                run(i + 1)
            }
        }
    }
    MLXServeStore.shared.prepare { _ in run(0) }
    RunLoop.main.run()
}

// Half-typed words: LocalType --selftest-halfwords ["text" …] (LT_PLACE="Safari on reddit.com" sets the app) — for each text, what the first press of the word key
// would insert (typo fix or model suggestion), flagging a space inside the word being finished.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-halfwords" {
    var texts = Array(CommandLine.arguments.dropFirst(2)).filter { !$0.hasPrefix("-") }
    if texts.isEmpty {
        texts = ["Nos vemos mañana en la universi", "Muchas gracias por tu ayu", "Hasta mañ",
                 "Quedamos el próximo vier", "Te mando el docu", "Perfecto, lo reviso esta tar", "Un sal",
                 "Me parece buena ide", "Necesito que me confir", "I'll send you the docum", "Thanks, I really apprec",
                 "See you tomor", "Could you plea", "Let me know if you have any ques", "I'm looking forw",
                 "Vamos mañana al par", "Te llamo esta tar", "Nos vemos esta tar", "Mañana tengo la reu"]
    }
    var bad = 0
    // The join rule with fixed replies (text, reply, expected suggestion).
    let joins: [(String, String, String)] = [
        ("Perfecto, lo reviso esta tar", "de y te digo algo", "de y te digo algo"),
        ("Vamos mañana al par", "que con los niños", "que con los niños"),
        ("Necesito que me lo confir", "mes cuanto antes", "mes cuanto antes"),
        ("Gracias por tu ayu", "da con todo", "da con todo"),
        ("I'm going in", "to the store later", " to the store later"),
        ("See you tom", "orrow then", "orrow then"),
        ("I'll send the docum", "ents today", "ents today"),
        ("Thanks for the update", "Talk soon", ""),   // no full stop: a run-on, not "updateTalk"
        ("Te escribo para con", "firmar el contrato", "firmar el contrato"),
        ("Te llamo esta tar", "che", "de"),
        ("Could you plea", "sease let me know", ""),
        ("I'll be there in", "five minutes", " five minutes"),
        ("We should meet some", "time next week", "time next week"),
        ("ok sounds good", "see you then", " see you then"),
        ("Hi there", "Ramiro here", " Ramiro here"),
        ("Te llamo esta tar", "je para confirmar la reunión", "de para confirmar la reunión"),
        ("Te llamo esta tar", "jeunta", "de"),
        ("Thanks, I really apprec", "your help", "iate your help"),
        ("Do you know if the train to Madrid", "is on time", " is on time"),
        ("Nos vemos mañana en la universi", "¡Nos vemos mañana en la universidad!", "dad!"),
        ("Thanks for the quick repl", "y You're welcome!", "y"),
        ("Mañana tengo la reu", "nión Mañana tengo la reunión.", "nión"),
        ("I'll see you on", "Monday at the office", " Monday at the office"),
        ("Our revenue was", "[the amount we agreed]", ""),
        ("Steps:\n1. Open the app\n2. Click Settings\n", "1. Open the app", ""),
        ("Thanks for the update, I'll", "look into it", " look into it"),
        ("Sounds good, we're", "all set then", " all set then"),
    ]
    for (text, reply, want) in joins {
        let got = ChatCompletion.finish(reply, cut: false, context: "", prefix: text)
        if got != want { bad += 1 }
        print("\(got == want ? "✓" : "✗") join: …\(text.suffix(24)) + \(reply.debugDescription) → \(got.debugDescription)\(got == want ? "" : " (want \(want.debugDescription))")")
    }
    for (word, text) in [("mañan", "Nos vemos mañan"), ("confir", "Necesito que me confir"), ("apprec", "Thanks, I really apprec")] {
        let t = Controller.checkTypo(word, in: text)
        print("typo check \(word.debugDescription) in \(Spelling.language(of: text) ?? "?"): \(t == nil ? "not a typo" : "typo, fix \((t! ?? "none").debugDescription)")")
    }
    func run(_ i: Int) {
        guard i < texts.count else { print("\n\(texts.count + joins.count - bad)/\(texts.count + joins.count) clean"); exit(bad == 0 ? 0 : 1) }
        let prefix = texts[i]
        func report(_ kind: String, _ inserted: String, deleting: Int = 0) {
            let result = String(prefix.dropLast(deleting)) + inserted
            let tail = String(prefix.reversed().prefix { $0.isLetter }.reversed())
            // The word being finished: from where it starts in the result up to its first space.
            let start = result.index(result.startIndex, offsetBy: prefix.count - tail.count)
            let spaced = !tail.isEmpty && (result[start...].first { !$0.isLetter && !"'’-".contains($0) }.map { $0 == " " } ?? false)
                && inserted.first.map { $0 == " " || deleting > 0 } == true
            if spaced { bad += 1 }
            print("\(spaced ? "✗" : "✓") \(kind): …\(prefix.suffix(28)) → …\(result.suffix(36).debugDescription)")
        }
        if Settings.typoGuard, let word = Controller.currentWord(prefix), let typo = Controller.checkTypo(word, in: prefix) {
            if let fix = typo { report("fix", fix, deleting: word.count) } else { print("· no suggestion (typo, no fix): …\(prefix.suffix(28))") }
            return run(i + 1)
        }
        // Same path as LLM.complete, keeping the raw reply to show next to the result.
        let hint = ChatCompletion.unfinishedWordHint(prefix)
        let context = "[Writing in \(ProcessInfo.processInfo.environment["LT_PLACE"] ?? "Mail")]\n" + (hint ?? "") + "\n"
        guard let req = ChatCompletion.request(context: context, text: prefix, maxTokens: Settings.effectiveMaxTokens) else { exit(1) }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let reply = data.flatMap(ChatCompletion.parse)
            let joined = reply.map { ChatCompletion.join($0.text, after: prefix, cut: $0.cut) } ?? ""
            let out = ChatCompletion.dropAssistantReply(ChatCompletion.dropLanguageSwitch(
                ChatCompletion.dropInventedFigures(joined, context: context + prefix), prefix: prefix), prefix: prefix)
            DispatchQueue.main.async {
                let text = Controller.clean(out, prefix: prefix)
                if text.isEmpty { print("· no suggestion: …\(prefix.suffix(28))") } else { report("model", Controller.splitWord(text).word) }
                print("    raw reply \((reply?.text ?? "nil").debugDescription)\(hint.map { "  hint " + $0.trimmingCharacters(in: .newlines) } ?? "")")
                run(i + 1)
            }
        }.resume()
    }
    MLXServeStore.shared.prepare { _ in run(0) }
    RunLoop.main.run()
}

// Local work per suggestion: LocalType --selftest-speed — replays sentences keystroke by keystroke through the checks a
// suggestion goes through besides the model (typo check, unfinished-word hint, join, guards) and reports the time.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-speed" {
    let sentences = ["Te llamo esta tarde para contarte más sobre el tema de la reunión",
                     "Thanks for sending the slides over, I really appreciate your help with the documentation",
                     "Mañana tengo la reunión con el equipo y luego te confirmo si podemos quedar"]
    let reply = "de para confirmar"
    var times: [Double] = [], parts = [0.0, 0.0, 0.0, 0.0]
    for sentence in sentences {
        var prefix = ""
        for ch in sentence {
            prefix.append(ch)
            let t0 = Date()
            if let w = Controller.currentWord(prefix) { _ = Controller.checkTypo(w, in: prefix) }
            let t1 = Date()
            _ = ChatCompletion.unfinishedWordHint(prefix)
            let t2 = Date()
            let j = ChatCompletion.join(reply, after: prefix)
            let t3 = Date()
            _ = ChatCompletion.dropAssistantReply(ChatCompletion.dropLanguageSwitch(ChatCompletion.dropInventedFigures(j, context: prefix), prefix: prefix), prefix: prefix)
            let t4 = Date()
            for (i, (a, b)) in [(t0, t1), (t1, t2), (t2, t3), (t3, t4)].enumerated() { parts[i] += b.timeIntervalSince(a) * 1000 }
            times.append(t4.timeIntervalSince(t0) * 1000)
        }
    }
    let n = Double(times.count)
    print(String(format: "per keystroke: typo check %.2f ms, hint %.2f ms, join %.2f ms, guards %.2f ms", parts[0] / n, parts[1] / n, parts[2] / n, parts[3] / n))
    let sorted = times.sorted()
    print(String(format: "%d keystrokes: mean %.2f ms, median %.2f ms, p95 %.2f ms, max %.2f ms (first %.2f ms)",
                 times.count, times.reduce(0, +) / Double(times.count), sorted[sorted.count / 2],
                 sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, times[0]))
    exit(0)
}

// Emoji matcher check: LocalType --selftest-emoji "I love this :fir" ":thumbs_u" …
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest-emoji" {
    var emojiArgs = Array(CommandLine.arguments.dropFirst(2)), texts: [String] = []
    while !emojiArgs.isEmpty {   // "-key value" pairs are argument-domain settings, not texts
        let a = emojiArgs.removeFirst()
        if a.hasPrefix("-"), !a.hasPrefix("--"), a.count > 2, !emojiArgs.isEmpty, a.dropFirst().first!.isLetter { emojiArgs.removeFirst() } else { texts.append(a) }
    }
    for text in texts {
        if let (item, n) = Emoji.emoticon(in: text) { print("\(text.debugDescription) → emoticon (\(n)): \(item.char)"); continue }
        let q = Emoji.query(in: text)
        let hits = q.map { Emoji.search($0.query) } ?? []
        print("\(text.debugDescription) → query \(q.map { "\"\($0.query)\" (\($0.length))" } ?? "nil"): " + hits.map { "\($0.char) \($0.name)" }.joined(separator: ", "))
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

// A --selftest flag that didn't run above is missing its arguments: say how to use it rather than start a second copy
// of the app.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1].hasPrefix("--selftest") {
    print("""
        Usage (all print results and exit; "-key value" pairs override settings without saving them):
          --selftest <model.gguf> <prompt>     built-in engine, two rounds (cache reuse)
          --selftest-mlx "text" …              suggestions from MLX-Serve for each text
          --selftest-prompts                   prompt test set through the configured engine
          --selftest-halfwords ["text" …]      half-typed words: join rules and live suggestions (LT_PLACE sets the app)
          --selftest-speed                     local work per keystroke besides the model
          --selftest-field <bundle ID>         read that app's focused field and suggest
          --selftest-practice                  the Setup window's Try-it box
          --selftest-labs                      alternatives and synonyms
          --selftest-emoji "text" …            emoji matching
          --selftest-screen <pid>              screen text recognition for that app
          --selftest-sync                      two simulated Macs (set LOCALTYPE_SUPPORT_DIR)
          --selftest-update                    version compare and update check
        """)
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
