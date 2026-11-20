// Renders LocalType's app icon (Resources/AppIcon.icns): an indigo rounded square with a text cursor and a
// faded "ghost" continuation, following Apple's macOS icon grid (824 pt body on a 1024 pt canvas).
// Run: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)   // draw in 1024-pt units at any pixel size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Soft drop shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor(srgbRed: 0.33, green: 0.30, blue: 0.86, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Indigo-to-violet gradient with a light sheen at the top.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.46, green: 0.43, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.31, green: 0.27, blue: 0.85, alpha: 1),
                        NSColor(srgbRed: 0.25, green: 0.20, blue: 0.70, alpha: 1)])!.draw(in: body, angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Typed text "Aa" in white, then the caret, then a faded continuation: the app in one picture.
    let font = NSFont.systemFont(ofSize: 300, weight: .semibold)
    let typed = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: NSColor.white])
    let ghost = NSAttributedString(string: "b", attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.38)])
    let tw = typed.size().width, gw = ghost.size().width, caretW: CGFloat = 26, gap: CGFloat = 18
    let total = tw + gap + caretW + gap + gw
    let x0 = body.midX - total / 2, baseY = body.midY - 110
    typed.draw(at: NSPoint(x: x0, y: baseY))
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: x0 + tw + gap, y: body.midY - 165, width: caretW, height: 330), xRadius: 13, yRadius: 13).fill()
    ghost.draw(at: NSPoint(x: x0 + tw + gap + caretW + gap, y: baseY))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! render(pt * scale).write(to: set.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
