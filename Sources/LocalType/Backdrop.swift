import AppKit
import ScreenCaptureKit

/// Samples the field's background color next to the caret with a tiny screenshot (Screen Recording permission),
/// so suggestions can match their surroundings: readable contrast on any page, and a solid backing when the
/// suggestion has to sit over existing text. LocalType's own windows are left out of the capture.
enum Backdrop {
    /// `rect` in global top-left coordinates (Accessibility space). Calls back on the main thread.
    static func sample(_ rect: CGRect, done: @escaping (NSColor?) -> Void) {
        guard ScreenContext.permitted, rect.width >= 1, rect.height >= 1 else { return done(nil) }
        Task.detached(priority: .userInitiated) {
            let color = await capture(rect)
            await MainActor.run { done(color) }
        }
    }

    private static func capture(_ r: CGRect) async -> NSColor? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.frame.intersects(r) }) else { return nil }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        cfg.width = max(1, Int(r.width))     // one pixel per point is plenty for a color
        cfg.height = max(1, Int(r.height))
        cfg.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return nil }
        return dominant(img)
    }

    /// Most common color (quantized), i.e. the background even when a few glyphs are in the strip.
    static func dominant(_ img: CGImage) -> NSColor? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var counts: [UInt16: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let key = UInt16(r >> 4) << 8 | UInt16(g >> 4) << 4 | UInt16(b >> 4)
            var c = counts[key] ?? (0, 0, 0, 0)
            c.n += 1; c.r += r; c.g += g; c.b += b
            counts[key] = c
        }
        guard let best = counts.values.max(by: { $0.n < $1.n }) else { return nil }
        let n = CGFloat(best.n) * 255
        return NSColor(srgbRed: CGFloat(best.r) / n, green: CGFloat(best.g) / n, blue: CGFloat(best.b) / n, alpha: 1)
    }

    /// Perceived brightness, 0…1.
    static func luminance(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
    }
}
