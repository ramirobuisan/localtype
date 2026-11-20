import AppKit

/// Click-through floating panel that shows the suggestion at the caret: inline ghost text in the field's own font
/// (default), or a small bubble. Typo fixes strike through the typo and show the fix after it.
final class Overlay {
    private let panel: NSPanel
    private let container = NSView()
    private let bubble = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "⇥")
    private let strike = NSView()

    /// Font and color of the field the suggestion belongs to (set before each show).
    var fieldStyle: TextStyle?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = container

        bubble.material = .popover
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 5
        bubble.layer?.masksToBounds = true

        label.lineBreakMode = .byClipping
        hint.font = .systemFont(ofSize: 10, weight: .semibold)
        hint.textColor = .tertiaryLabelColor
        strike.wantsLayer = true
        strike.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        for v in [bubble, strike, label, hint] { container.addSubview(v) }
    }

    private var inline: Bool { Settings.suggestionStyle == 0 }

    private func font(_ caret: NSRect) -> NSFont {
        if inline, let f = fieldStyle?.font { return f }
        return .systemFont(ofSize: max(11, min(caret.height * 0.8, 20)))
    }

    /// Ghost-text color: the field's text color, faded; falls back to the system's secondary label color.
    private var ghostColor: NSColor {
        guard inline, let c = fieldStyle?.color?.usingColorSpace(.sRGB), c.alphaComponent > 0.2 else { return .secondaryLabelColor }
        return c.withAlphaComponent(0.42)
    }

    private var acceptHint: String { (Settings.keyAcceptWord ?? Settings.keyAcceptAll)?.display ?? "⇥" }

    /// A suggestion, or a typo fix. For a fix, `typo` is the screen rect of the misspelled word to strike through.
    func show(_ text: String, at caret: NSRect, isFix: Bool = false, typo: NSRect? = nil) {
        let f = font(caret)
        if isFix {
            let s = inline && typo != nil ? " " + text : "✎ " + text
            present(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.systemOrange]),
                    hint: acceptHint, at: caret, strikeThrough: inline ? typo : nil)
        } else {
            present(NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: ghostColor]), hint: acceptHint, at: caret)
        }
    }

    /// The selected emoji and its name, followed by the other matches; ↓ / ↑ cycle through them.
    func showEmoji(_ items: [Emoji.Item], selected: Int, at caret: NSRect) {
        let f = font(caret)
        let small = NSFont.systemFont(ofSize: max(10, f.pointSize * 0.8))
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: items[selected].char + " ", attributes: [.font: NSFont.systemFont(ofSize: f.pointSize)]))
        if !items[selected].name.isEmpty {
            s.append(NSAttributedString(string: items[selected].name, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let others = items.indices.filter { $0 != selected }.map { items[$0].char }
        if !others.isEmpty {
            s.append(NSAttributedString(string: "   " + others.joined(separator: " "), attributes: [
                .font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        // Emoji always get the bubble: they're a picker, not ghost text.
        present(s, hint: others.isEmpty ? acceptHint : acceptHint + " · ↓ next", at: caret, forceBubble: true)
    }

    private func present(_ text: NSAttributedString, hint hintText: String, at caret: NSRect,
                         strikeThrough typo: NSRect? = nil, forceBubble: Bool = false) {
        let useBubble = !inline || forceBubble
        label.attributedStringValue = text
        hint.stringValue = hintText
        label.sizeToFit()
        hint.sizeToFit()

        // NSTextField labels draw 2 pt in from their frame; inline text must start exactly at the caret.
        let inset: CGFloat = 2
        let padX: CGFloat = useBubble ? 5 : 0, gap: CGFloat = useBubble ? 6 : 4
        let lead = typo.map { max(0, caret.maxX - $0.minX) } ?? 0   // room on the left for the struck typo
        let w = lead + padX + label.frame.width - (useBubble ? 0 : inset) + gap + hint.frame.width + padX
        let h = max(label.frame.height, caret.height) + (useBubble ? 2 : 0)
        label.frame.origin = NSPoint(x: lead + padX - (useBubble ? 0 : inset), y: (h - label.frame.height) / 2)
        hint.frame.origin = NSPoint(x: label.frame.maxX + gap - (useBubble ? 0 : inset), y: (h - hint.frame.height) / 2)
        bubble.isHidden = !useBubble
        bubble.frame = NSRect(x: lead, y: 0, width: w - lead, height: h)
        if let typo {
            strike.isHidden = false
            strike.frame = NSRect(x: 0, y: (h / 2).rounded(), width: typo.width, height: 1.5)
        } else {
            strike.isHidden = true
        }

        var origin = NSPoint(x: caret.maxX + (useBubble ? 1 : 0) - lead, y: caret.midY - h / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: caret.maxX, y: caret.midY)) }) ?? NSScreen.main {
            origin.x = min(origin.x, screen.visibleFrame.maxX - w)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
