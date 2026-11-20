import AppKit
import ScreenCaptureKit
import Vision

/// Text recognized (on-device, Vision OCR) in the window you're typing in, used as extra context.
/// Captures run off the main thread and are cached per window, so they never delay a suggestion:
/// a completion uses whatever text is cached for that window, and a stale cache triggers a new capture.
final class ScreenContext {
    static let shared = ScreenContext()

    struct Line { let text: String; let midY: CGFloat }   // midY: global top-left coordinates

    // Main-thread confined.
    private var cache: (pid: pid_t, frame: CGRect, date: Date, lines: [Line])?
    private var inFlight = false
    private static let maxAge: TimeInterval = 4
    private static let maxPixelWidth: CGFloat = 2400

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func clear() { cache = nil }

    /// Center of the window in the cache (for the self-test, which has no caret).
    var lastFrameCenter: CGPoint? { cache.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } }

    /// Starts a background capture if the cache isn't for the window under the caret, or is old.
    /// `caret` is in global top-left coordinates (the Accessibility API's space).
    func refreshIfStale(pid: pid_t, caret: CGPoint) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !inFlight, ScreenContext.permitted else { return }
        if let c = cache, c.pid == pid, c.frame.contains(caret), Date().timeIntervalSince(c.date) < ScreenContext.maxAge { return }
        inFlight = true
        Task.detached(priority: .utility) {
            let result = await ScreenContext.capture(pid: pid, caret: caret)
            await MainActor.run {
                self.inFlight = false
                if let result { self.cache = (pid, result.frame, Date(), result.lines) }
            }
        }
    }

    /// Cached text for the window under the caret: lines nearest the caret first (shown in reading order),
    /// at most `limit` characters, without lines that are already part of the text being typed.
    func text(pid: pid_t, caret: CGPoint, excluding prefix: String, limit: Int = 1200) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let c = cache, c.pid == pid, c.frame.contains(caret), Date().timeIntervalSince(c.date) < 60 else { return nil }
        let typed = ScreenContext.normalize(prefix)
        let candidates = c.lines.filter { line in
            let n = ScreenContext.normalize(line.text)
            return n.count >= 3 && !typed.contains(n)
        }
        var picked: [Line] = []
        var total = 0
        for line in candidates.sorted(by: { abs($0.midY - caret.y) < abs($1.midY - caret.y) }) {
            if total + line.text.count + 1 > limit { continue }
            picked.append(line); total += line.text.count + 1
        }
        guard !picked.isEmpty else { return nil }
        return picked.sorted { $0.midY < $1.midY }.map(\.text).joined(separator: " / ")
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
            return Line(text: text, midY: f.minY + (1 - obs.boundingBox.midY) * f.height)
        }
        return (f, lines)
    }
}
