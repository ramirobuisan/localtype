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
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[2]).first else {
        print("not running"); exit(1)
    }
    AX.enableAccessibility(for: app)
    // A browser in the background may report no focused element: the first text area in its windows will do.
    func firstTextArea(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success, v as? String == kAXTextAreaRole { return el }
        guard depth < 40, AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return nil }
        for k in kids { if let f = firstTextArea(k, depth: depth + 1) { return f } }
        return nil
    }
    guard let el = AX.focusedElement(ofApp: app.processIdentifier) ?? firstTextArea(AXUIElementCreateApplication(app.processIdentifier)) else {
        print("no focused element"); exit(1)
    }
    let title = AX.windowTitle(of: el), field = AX.fieldFrame(of: el)
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    let prefix: String, caret: CGPoint, place: String?
    if let ctx = AX.readContext(element: el) {
        print("prefix: …\(ctx.prefix.suffix(50).debugDescription) (\(ctx.prefix.count) chars)")
        print("caret: \(ctx.caretRect) line height \(ctx.lineHeight)")
        print("font: \(ctx.style.map { "\($0.font.fontName) \($0.font.pointSize)" } ?? "unknown (system font fallback)")")
        print("domain: \(ctx.domain ?? "none") · prompt place: \(ctx.place ?? "none")")
        (prefix, caret, place) = (ctx.prefix, ctx.caretPoint, ctx.place)
    } else {
        // A browser in the background doesn't lay out its caret: the rest can still be checked with the caret at the
        // start of the field.
        var v: CFTypeRef?
        guard let f = field, AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let text = v as? String else {
            print("readContext: nil — LocalType would not suggest here (see a field probe for which check fails)"); exit(1)
        }
        print("readContext: nil (no caret position; an app in the background often has none) — caret taken as the field's start")
        let app = NSRunningApplication(processIdentifier: pid)
        let domain = AX.webDomain(of: el)
        (prefix, caret, place) = (text, CGPoint(x: f.minX + 4, y: f.minY + 12),
                                  domain.map { "\(app?.localizedName ?? "") on \($0)" } ?? app?.localizedName)
    }
    // The screen text as a suggestion would get it (needs "Screen context" on and Screen Recording).
    print("window: \(title.map { $0.debugDescription } ?? "nil") · field: \(field.map { "\($0)" } ?? "none")")
    let t0 = Date()
    ScreenContext.shared.prepare(pid: pid, caret: caret, title: title, timeout: 30) {
        var screen: String?
        if Settings.useScreen {
            let whole = ScreenContext.shared.text(pid: pid, caret: caret, title: title, field: nil, excluding: prefix)
            screen = ScreenContext.shared.text(pid: pid, caret: caret, title: title, field: field, excluding: prefix)
            print("── screen [\(Int(Date().timeIntervalSince(t0) * 1000)) ms], whole window:\n\(whole ?? "none")\n── for this field:\n\(screen ?? "none")\n──")
        }
        let t1 = Date()
        MLXServeStore.shared.prepare { _ in
            LLM().complete(prefix: prefix, appName: place, screen: screen) { out in
                print("suggestion [\(Int(Date().timeIntervalSince(t1) * 1000)) ms]: \(out.map { $0.debugDescription } ?? "nil")")
                exit(0)
            }
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
    let allCases: [(String, String, String?, [String])] = [
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
        ("Mail", "Hi Laura,\n\nSure! I'll send you the", "Laura: Could you send me the Q3 budget numbers before Friday's board meeting?", ["screen:Q3|budget|numbers|Friday"]),
        ("Mail", "Thanks for the update. ", nil, ["en"]),
        ("Messages", "ok sounds good, see you", nil, ["en"]),
        ("Mail", "Hi Tom,\n\n", nil, ["en"]),
        ("Slack", "Thanks for the update, I'll", nil, ["en", "starts: "]),
        ("TextEdit", "Te llamo esta tarde para confirmar los detalles.", nil, ["es", "starts: ", "words:2"]),
        ("Mail", "Thanks for your help with this.", nil, ["en", "starts: ", "words:2"]),
        ("Google Chrome on github.com", "Thanks for the PR! The changes look good, but could you", nil, ["en"]),
        ("Safari on mail.google.com", "Hola Pablo,\n\nTe adjunto", nil, ["es"]),
        ("Google Chrome on reddit.com", "hole", nil, ["noassistant"]),
        ("Notes", "banana", nil, ["noassistant"]),
        ("WhatsApp", "Te llamo esta tar", nil, ["starts:de"]),
        ("Messages", "Nos vemos esta tar", nil, ["starts:de"]),
        ("Mail", "Mañana tengo la reu", nil, ["starts:ni"]),
        ("Mail", "Thanks for the quick repl", nil, ["starts:y"]),
        // Replies to what's on screen, as the screen reader passes it (one line per block of text, top to bottom,
        // with the window's own labels and timestamps).
        ("Slack", "I had a look at the",
         "# design-team\nMarta Ruiz 10:42\nHey! Did anyone get a chance to review the new onboarding mockups? I need feedback by tomorrow\n👀 2\nCarlos Vega 10:45\nI'll look at them after lunch\nMessage #design-team",
         ["en", "screen:mockup|onboarding|design|screen|flow"]),
        ("WhatsApp", "Sí, allí estaré! ",
         "Mamá\nen línea\n¿Vienes a comer el domingo? Hago paella 🥘 12:03\n¿Traes tú el postre? 12:04",
         ["es", "screen:postre|tarta|helado|llevo|paella|comida|domingo|flan|pastel"]),
        ("Mail", "Hi David,\n\nThanks for the reminder. I'd like to",
         "Contract renewal\nDavid Chen\nTo: Ramiro Buisan\nHi Ramiro,\nThe current contract ends on 30 November. Could you confirm whether you want to renew it for another year, or should we discuss changes first?\nBest,\nDavid",
         ["en", "screen:renew|contract|discuss|change|year"]),
        ("Safari on reddit.com", "honestly for that workload",
         "r/macbookair · 3h\nIs the M4 MacBook Air worth it for programming?\nI'm a CS student and mostly use VS Code, Docker and some light ML. Is 16 GB enough or should I get 24?\n142 comments Share\nAdd a comment",
         ["en", "screen:16|24|GB|RAM|memory|enough|fine|plenty|Docker|Air|more"]),
        ("Messages", "Yes! ",
         "Laura\niMessage\nToday 18:20\nAre you still coming to the concert on Friday?\nDelivered",
         ["en", "screen:concert|Friday|ticket|there|wait|see you|excited|coming"]),
        ("Google Chrome on github.com", "Thanks for tracking this down! Could you add a",
         "Fix race condition in cache invalidation #482\nalexk wants to merge 3 commits into main from fix/cache-race\nConversation 2 Commits 3 Checks 4 Files changed 5\nThe cache could be cleared while a request was still reading it. This adds a lock around the read path.",
         ["en", "screen:test|lock|cache|race|comment|regression|read"]),
        ("Mail", "Hola Elena,\n\nEl jueves",
         "Reunión del proyecto\nElena Martín\nPara: Ramiro\nHola Ramiro, ¿te va bien el jueves a las 10 para revisar el proyecto? Si no, dime otra hora.\nUn saludo,\nElena",
         ["es", "screen:me va|perfecto|bien|10|hora|nos vemos|reuni|proyecto|revis"]),
        // The screen reader missed the column: other chats from the list are mixed in.
        ("WhatsApp", "Claro, ",
         "Chats\nPablo Gym\njajaja vale 11:20\nTrabajo USJ\nElena: el viernes entrego 10:58\nMamá\n¿Traes tú el postre? 12:04\nMamá\nen línea\n¿Vienes a comer el domingo? Hago paella 🥘 12:03\n¿Traes tú el postre? 12:04",
         ["es", "screen:postre|tarta|helado|llevo|paella|comida|domingo|flan|pastel"]),
    ]
    // LT_CASES=screen runs only the cases with something on screen; other text, the cases whose text contains it
    // (LT_REPEAT=n runs each n times).
    let only = ProcessInfo.processInfo.environment["LT_CASES"]
    let picked = only == "screen" ? allCases.filter { $0.2 != nil } : only.map { o in allCases.filter { $0.1.contains(o) } } ?? allCases
    let cases = Array(repeating: picked, count: Int(ProcessInfo.processInfo.environment["LT_REPEAT"] ?? "") ?? 1).flatMap { $0 }
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
                if k.hasPrefix("starts:"), !s.hasPrefix(String(k.dropFirst(7))) { bad.append("wrong start (want \(k.dropFirst(7).debugDescription)…)") }
                if k == "starts: ", s.hasPrefix("  ") { bad.append("double space") }
                if k.hasPrefix("words:"), t.split(separator: " ").count < Int(k.dropFirst(6))! { bad.append("too short") }
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
        ("Could you add a", "a quick comment on the PR?", " quick comment on the PR?"),
        ("Nos vemos a las 10 en la", "la cafetería de siempre", " cafetería de siempre"),
        ("I think that", "that would work", " would work"),
        ("Could you add a ", "a quick comment", "quick comment"),
        ("Claro, ", "I'll bring the dessert tomorrow.", ""),
        ("Sure, ", "I'll bring the dessert tomorrow.", "I'll bring the dessert tomorrow."),
        ("Vale, ", "nos vemos allí a las ocho.", "nos vemos allí a las ocho."),
        ("I am writing to apply for the", "[Unfinished word \"pos\": position] position advertised online.", " position advertised online."),
        ("I am writing to apply for the", "[Unfinished word \"pos\": position]", ""),
        ("I'll send the docum", "docum", "ent"),
        ("Te llamo esta tarde para confirmar los detalles.", "Te llamo esta tarde para confirmar los detalles. ¿Te", " ¿Te"),
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
    print("OCR languages: \(ScreenContext.languages(supported: (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []))")
    func round(_ n: Int) {
        let t0 = Date()
        ScreenContext.shared.clear()
        ScreenContext.shared.prepare(pid: pid, caret: CGPoint(x: -1, y: -1), title: nil, timeout: 60) {
            let text = ScreenContext.shared.text(pid: pid, caret: ScreenContext.shared.lastFrameCenter ?? .zero, title: nil, field: nil, excluding: "")
            guard let text else { print("no text captured"); exit(1) }
            print("round \(n) [\(Int(Date().timeIntervalSince(t0) * 1000)) ms] \(text.count) chars: \(text.prefix(200))")
            // Second round: a warm capture, as during normal typing.
            if n == 2 { exit(0) } else { round(2) }
        }
    }
    round(1)
    RunLoop.main.run()
}

// Screen text selection: LocalType --selftest-screen-layout — opens a mock chat window (a list of other chats beside
// the conversation, and a reply box), captures it like any other window and checks the text a suggestion would get.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest-screen-layout" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let size = NSSize(width: 920, height: 560)
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    win.title = "design-team - Acme - Chat"
    win.center()
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.white.cgColor
    win.contentView = root
    func label(_ s: String, _ x: CGFloat, _ top: CGFloat, width: CGFloat = 200, size fontSize: CGFloat = 13, bold: Bool = false) {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: fontSize) : .systemFont(ofSize: fontSize)
        l.textColor = .black
        l.preferredMaxLayoutWidth = width
        let h = l.sizeThatFits(NSSize(width: width, height: 1000)).height
        l.frame = NSRect(x: x, y: size.height - top - h, width: width, height: h)
        root.addSubview(l)
    }
    let sidebar = [("Acme Inc", true), ("# general", false), ("# design-team", false), ("# random", false),
                   ("Direct messages", true), ("Pablo Gómez", true), ("the invoice is paid, thanks", false),
                   ("Lucía Ortega", true), ("see you at the gym tonight", false)]
    for (i, (s, b)) in sidebar.enumerated() { label(s, 16, 20 + CGFloat(i) * 34, bold: b) }
    // The conversation: a title, two messages. show() switches it, as clicking another chat would.
    var shown: [NSTextField] = []
    func show(_ title: String, _ messages: [(String, String)]) {
        shown.forEach { $0.removeFromSuperview() }
        let before = Set(root.subviews.map(ObjectIdentifier.init))
        label("# " + title, 260, 20, width: 400, size: 15, bold: true)
        var top: CGFloat = 90
        for (who, text) in messages {
            label(who, 260, top, width: 300, bold: true)
            label(text, 260, top + 22, width: 560)
            top += 110
        }
        shown = root.subviews.filter { !before.contains(ObjectIdentifier($0)) }.compactMap { $0 as? NSTextField }
        win.title = title + " - Acme - Chat"
        root.display()
    }
    show("design-team", [("Marta Ruiz   10:42", "Hey! Did anyone get a chance to review the new onboarding mockups? I need feedback by tomorrow morning so I can send them to the client before the review."),
                         ("Carlos Vega   10:45", "I'll look at them after lunch")])
    let typed = "I had a look at the"
    let box = NSTextField(string: typed)
    box.font = .systemFont(ofSize: 13)
    box.frame = NSRect(x: 250, y: 20, width: 650, height: 28)
    root.addSubview(box)
    win.orderFrontRegardless()

    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let cocoa = win.convertToScreen(box.convert(box.bounds, to: nil))
    let field = CGRect(x: cocoa.minX, y: primaryH - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    let caret = CGPoint(x: field.minX + 130, y: field.midY)
    let pid = ProcessInfo.processInfo.processIdentifier
    var bad: [String] = []
    func screen(_ then: @escaping (String, Int) -> Void) {
        let t0 = Date()
        ScreenContext.shared.prepare(pid: pid, caret: caret, title: win.title, timeout: 30) {
            then(ScreenContext.shared.text(pid: pid, caret: caret, title: win.title, field: field, excluding: typed) ?? "",
                 Int(Date().timeIntervalSince(t0) * 1000))
        }
    }
    func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
    after(0.8) {
        screen { picked, ms in
            let whole = ScreenContext.shared.text(pid: pid, caret: caret, title: win.title, field: nil, excluding: "") ?? "nil"
            print("── whole window (\(ms) ms):\n\(whole)\n── for the reply box:\n\(picked)")
            for s in ["random", "Pablo", "invoice", "gym", "Direct messages"] where picked.contains(s) { bad.append("other chats (\(s))") }
            if picked.contains("I had a look") { bad.append("the reply box's own text") }
            if !picked.split(separator: "\n").contains(where: { $0.contains("Did anyone") && $0.contains("before the review") }) {
                bad.append("wrapped message not joined")
            }
            if !picked.contains("after lunch") { bad.append("missed the last message") }
            // Nothing changed: the cached text, at once.
            screen { _, ms in
                print("── unchanged: \(ms) ms")
                if ms > 20 { bad.append("waited with nothing changed") }
                // Another chat in the same window (its title changes): a new capture, not the old chat's text.
                show("random", [("Pablo Gómez   11:02", "Who wants to order pizza for the team lunch on Friday?")])
                after(0.2) {
                    screen { picked, ms in
                        print("── another chat (\(ms) ms):\n\(picked)")
                        if !picked.contains("pizza") || picked.contains("mockups") { bad.append("old chat's text after switching") }
                        // New content, same title (a chat app whose title never changes), after a click.
                        show("random", [("Lucía Ortega   11:10", "The printer on the second floor is broken again")])
                        win.title = "random - Acme - Chat"
                        ScreenContext.shared.screenMayHaveChanged()
                        after(0.2) {
                            screen { picked, ms in
                                print("── after a click (\(ms) ms):\n\(picked)")
                                if !picked.contains("printer") || picked.contains("pizza") { bad.append("old text after a click") }
                                print(bad.isEmpty ? "✓ ok" : "✗ " + bad.joined(separator: ", "))
                                exit(bad.isEmpty ? 0 : 1)
                            }
                        }
                    }
                }
            }
        }
    }
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
          --selftest-screen-layout             which screen text a reply box gets (opens a mock chat window)
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
