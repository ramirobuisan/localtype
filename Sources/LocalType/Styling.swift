import AppKit

// Shared look for LocalType's windows (System Settings style).

/// Grouped "card" like System Settings: soft fill, hairline border, rounded corners.
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 1, alpha: 0.9)).cgColor
        layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.07)).cgColor
    }
}

/// Hairline divider inside a card, inset to line up with the row text.
final class Divider: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).cgColor
    }
}

/// Colored rounded-square icon with a white symbol, as in System Settings' sidebar.
func iconTile(_ symbol: String, _ color: NSColor, size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: size * 0.235, yRadius: size * 0.235)
        let top = color.blended(withFraction: 0.18, of: .white) ?? color
        NSGradient(starting: top, ending: color)?.draw(in: path, angle: -90)
        // Monochrome symbol tinted white (palette mode fills some symbols' background layers).
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
        if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = sym.size
            let white = NSImage(size: s, flipped: false) { b in
                sym.draw(in: b)
                NSColor.white.set()
                b.fill(using: .sourceAtop)
                return true
            }
            white.draw(in: NSRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
}

