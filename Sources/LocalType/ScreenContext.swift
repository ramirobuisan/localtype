import AppKit
import ScreenCaptureKit
import Vision

/// Text recognized (on-device, Vision OCR) in the window you're typing in, used as extra context.
/// Captures run off the main thread and are cached per window. A suggestion uses the cached text while it's still
/// good; after anything that may have changed what the window shows (a click, another app, Return, a shortcut), or in
/// another window or tab, it waits briefly for a new capture instead of using text from the old one.
final class ScreenContext {
    static let shared = ScreenContext()

    /// A piece of recognized text and its box, in global top-left coordinates.
    struct Line { let text: String; let rect: CGRect }

    private struct Capture {
        let pid: pid_t, frame: CGRect, title: String?, date: Date, lines: [Line]
        let changes: Int   // `ScreenContext.changes` when the capture started
    }

    // Main-thread confined.
    private var cache: Capture?
    private var inFlight = false
    private var changes = 0
    private var waiting: [() -> Void] = []
    /// The last finished capture, usable or not: one that didn't cover the caret (a sheet, a floating panel) isn't
    /// waited for again until something changes.
    private var attempt: (pid: pid_t, title: String?, changes: Int, date: Date)?
    /// After this a capture is redone in the background (its text is still used meanwhile).
    private static let maxAge: TimeInterval = 4
    private static let maxPixelWidth: CGFloat = 2400

    /// CGPreflightScreenCaptureAccess takes ~10 ms, too long for every suggestion: a grant is remembered (macOS
    /// applies a new one at the next launch anyway), a refusal is checked again after a few seconds.
    private static let permissionLock = NSLock()
    private static var granted = false
    private static var checkedAt = Date.distantPast
    /// LT_SCREEN_BOXES=1 prints the picked lines with their boxes (development).
    private static let debugBoxes = ProcessInfo.processInfo.environment["LT_SCREEN_BOXES"] != nil

    static var permitted: Bool {
        permissionLock.lock(); defer { permissionLock.unlock() }
        if granted || Date().timeIntervalSince(checkedAt) < 3 { return granted }
        checkedAt = Date()
        granted = CGPreflightScreenCaptureAccess()
        return granted
    }
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func clear() { cache = nil }

    /// Something may have changed what's on screen (a click, another app in front, a sent message, a shortcut that
    /// switches tab or chat): the cached text isn't used again until a new capture.
    func screenMayHaveChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        changes += 1
    }

    /// Center of the window in the cache (for the self-test, which has no caret).
    var lastFrameCenter: CGPoint? { cache.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } }

    /// The cache is from this window (and tab: same `title`) and nothing has changed since it was taken.
    private func usable(pid: pid_t, caret: CGPoint, title: String?) -> Capture? {
        guard let c = cache, c.pid == pid, c.frame.contains(caret), c.title == title, c.changes == changes,
              Date().timeIntervalSince(c.date) < 60 else { return nil }
        return c
    }

    /// Calls `done` once the text for this window can be read with `text(…)`: at once while the cached capture is
    /// good (an old one is redone in the background), otherwise after a new capture or `timeout`, whichever is first.
    /// `caret` is in global top-left coordinates (the Accessibility API's space).
    func prepare(pid: pid_t, caret: CGPoint, title: String?, timeout: TimeInterval, _ done: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ScreenContext.permitted else { return done() }
        if let good = usable(pid: pid, caret: caret, title: title) {
            if Date().timeIntervalSince(good.date) > ScreenContext.maxAge { capture(pid: pid, caret: caret, title: title) }
            return done()
        }
        if !inFlight, let a = attempt, a.pid == pid, a.title == title, a.changes == changes,
           Date().timeIntervalSince(a.date) < ScreenContext.maxAge { return done() }
        capture(pid: pid, caret: caret, title: title)
        guard inFlight else { return done() }
        var called = false
        let once = { if !called { called = true; done() } }
        waiting.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: once)
    }

    private func capture(pid: pid_t, caret: CGPoint, title: String?) {
        guard !inFlight else { return }
        inFlight = true
        let stamp = changes, start = Date()
        Task.detached(priority: .userInitiated) {
            let result = await ScreenContext.capture(pid: pid, caret: caret)
            await MainActor.run {
                self.inFlight = false
                self.attempt = (pid, title, stamp, start)
                if let result { self.cache = Capture(pid: pid, frame: result.frame, title: title, date: start, lines: result.lines, changes: stamp) }
                let w = self.waiting
                self.waiting = []
                w.forEach { $0() }
            }
        }
    }

    /// Text of the window under the caret, if the cached capture is good for it (see `prepare`).
    func text(pid: pid_t, caret: CGPoint, title: String?, field: CGRect?, excluding prefix: String, limit: Int = 1200) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let c = usable(pid: pid, caret: caret, title: title) else { return nil }
        return ScreenContext.select(c.lines, window: c.frame, caret: caret, field: field, typed: prefix, limit: limit)
    }

    /// The recognized lines worth sending, as text: one line per row or paragraph, top to bottom, at most `limit`
    /// characters, nearest the caret first.
    /// - Only the column of the field being typed in, when the field is narrower than the window: a chat app's list
    ///   of other conversations (or a mail app's message list) beside the conversation is a different subject.
    /// - Not the field's own text up to the caret, which is already in the prompt (OCR may misread it, so this goes by
    ///   position, not by comparing text). What follows the caret, such as the message quoted in a reply, stays.
    /// - Lines below the field count as twice as far: under a reply box come other replies, above it what it answers.
    static func select(_ lines: [Line], window: CGRect, caret: CGPoint, field: CGRect?, typed prefix: String, limit: Int) -> String? {
        let typed = normalize(prefix)
        var candidates = lines.filter { line in
            let n = normalize(line.text)
            guard n.count >= 3, !typed.contains(n) else { return false }
            if let f = field, f.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)),
               line.rect.midY < caret.y + line.rect.height / 2 { return false }
            return true
        }
        if let f = field, f.width < window.width * 0.8 {
            let lo = f.minX - 24, hi = f.maxX + 24
            let column = candidates.filter { min($0.rect.maxX, hi) - max($0.rect.minX, lo) >= $0.rect.width / 2 }
            if column.reduce(0, { $0 + $1.text.count }) >= 40 { candidates = column }
        }
        let bottom = max(field?.maxY ?? caret.y, caret.y)
        func distance(_ l: Line) -> CGFloat {
            l.rect.midY > bottom ? (l.rect.midY - caret.y) * 2 : abs(l.rect.midY - caret.y)
        }
        var picked: [Line] = []
        var total = 0
        for line in candidates.sorted(by: { distance($0) < distance($1) }) {
            if total + line.text.count + 1 > limit { continue }
            picked.append(line); total += line.text.count + 1
        }
        guard !picked.isEmpty else { return nil }
        if debugBoxes {
            for l in picked.sorted(by: { $0.rect.minY < $1.rect.minY }) {
                print(String(format: "  box x %.0f–%.0f y %.1f–%.1f h %.1f  ", l.rect.minX, l.rect.maxX, l.rect.minY, l.rect.maxY, l.rect.height) + l.text.prefix(40))
            }
        }

        // Rows: pieces whose centers are within half a line of each other, left to right.
        var rows: [[Line]] = []
        for l in picked.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let first = rows.last?.first, abs(l.rect.midY - first.rect.midY) < min(l.rect.height, first.rect.height) / 2 {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        // A wrapped line joins the one above it: both single pieces, the same left edge and height, almost touching
        // (measured: ~0 pt between wrapped lines, 11 pt or more between messages), and the line above at least about
        // as wide (it was full; a name or time above a message is narrower).
        var out: [(text: String, rect: CGRect, last: CGRect?)] = []   // last: the block's bottom line, if a single piece
        for row in rows {
            let r = row.sorted { $0.rect.minX < $1.rect.minX }
            let rect = r.dropFirst().reduce(r[0].rect) { $0.union($1.rect) }
            let text = r.map(\.text).joined(separator: " · ")
            if r.count == 1, let prev = out.last, let above = prev.last, abs(rect.minX - above.minX) < 8,
               abs(rect.height - above.height) < rect.height * 0.3, rect.minY - above.maxY < rect.height * 0.35,
               above.width >= rect.width * 0.9 {
                out[out.count - 1] = (prev.text + " " + text, prev.rect.union(rect), rect)
            } else {
                out.append((text, rect, r.count == 1 ? rect : nil))
            }
        }
        return out.map(\.text).joined(separator: "\n")
    }

    /// Accurate recognition in the user's preferred languages. Explicit languages matter: automatic language
    /// detection costs ~14 s per image, versus ~130 ms (after a one-time model load) with a fixed list.
    private static func makeRequest() -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = languages(supported: (try? req.supportedRecognitionLanguages()) ?? [])
        return req
    }

    static func languages(supported: [String]) -> [String] {
        var out: [String] = []
        for pref in Locale.preferredLanguages {
            let base = pref.split(separator: "-").first.map(String.init) ?? pref
            if let m = supported.first(where: { $0 == pref }) ?? supported.first(where: { $0.hasPrefix(base + "-") || $0 == base }),
               !out.contains(m) { out.append(m) }
        }
        return out.isEmpty ? ["en-US"] : out
    }

    /// Loads the text-recognition model in the background (the first recognition in a process takes ~25 s),
    /// so the first real capture is fast.
    func prewarm() {
        guard Settings.useScreen else { return }
        Task.detached(priority: .background) {
            let size = 64
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let img = ctx.makeImage() else { return }
            try? VNImageRequestHandler(cgImage: img).perform([ScreenContext.makeRequest()])
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Capture + OCR (background)

    private static func capture(pid: pid_t, caret: CGPoint) async -> (frame: CGRect, lines: [Line])? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let mine = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 60 && $0.frame.height > 40
        }
        guard let window = mine.first(where: { $0.frame.contains(caret) }) ?? mine.first else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        let scale = min(CGFloat(filter.pointPixelScale), maxPixelWidth / max(window.frame.width, 1))
        cfg.width = max(1, Int(window.frame.width * scale))
        cfg.height = max(1, Int(window.frame.height * scale))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return nil }

        let req = makeRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([req]) } catch { return nil }

        let f = window.frame
        let lines: [Line] = (req.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence >= 0.3 else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision boxes are normalized with a bottom-left origin.
            let b = obs.boundingBox
            return Line(text: text, rect: CGRect(x: f.minX + b.minX * f.width, y: f.minY + (1 - b.maxY) * f.height,
                                                 width: b.width * f.width, height: b.height * f.height))
        }
        return (f, lines)
    }
}
