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

/// Settings → Appearance: what a suggestion looks like in the chosen style, on a sample sentence.
final class SuggestionPreview: NSView {
    var bubble = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }

    override func draw(_ dirty: NSRect) {
        // A text-field-like backdrop.
        let field = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill(); field.fill()
        NSColor.separatorColor.setStroke(); field.lineWidth = 0.5; field.stroke()

        let font = NSFont.systemFont(ofSize: 13)
        let typed = NSAttributedString(string: "Thanks for the update, I'll", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let h = typed.size().height
        let y = (bounds.height - h) / 2, x0: CGFloat = 10
        typed.draw(at: NSPoint(x: x0, y: y))
        let x = x0 + typed.size().width + 1
        NSColor.controlAccentColor.setFill()
        NSRect(x: x, y: y + 1, width: 1.5, height: h - 2).fill()

        let hintAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor]
        let hint = NSAttributedString(string: "⇥", attributes: hintAttrs)
        if bubble {
            let g = NSAttributedString(string: "send it over this afternoon.", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            let box = NSRect(x: x + 5, y: y - 3, width: g.size().width + hint.size().width + 18, height: h + 6)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            (NSColor.windowBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .windowBackgroundColor).setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
            g.draw(at: NSPoint(x: box.minX + 6, y: y))
            hint.draw(at: NSPoint(x: box.minX + 6 + g.size().width + 6, y: y + (h - hint.size().height) / 2))
        } else {
            let g = NSAttributedString(string: " send it over this afternoon.",
                                       attributes: [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.42)])
            g.draw(at: NSPoint(x: x + 1, y: y))
            hint.draw(at: NSPoint(x: x + 1 + g.size().width + 6, y: y + (h - hint.size().height) / 2))
        }
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

