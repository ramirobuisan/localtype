import AppKit

/// Click-through floating panel that shows the ghost suggestion at the caret.
final class Overlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "⇥")

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 5
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        label.textColor = .secondaryLabelColor
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 10, weight: .semibold)
        label.lineBreakMode = .byClipping
        bg.addSubview(label)
        bg.addSubview(hint)
    }

    private static func fontSize(_ caret: NSRect) -> CGFloat { max(11, min(caret.height * 0.8, 20)) }

    func show(_ text: String, at caret: NSRect, isFix: Bool = false) {
        let font = NSFont.systemFont(ofSize: Overlay.fontSize(caret))
        let color: NSColor = isFix ? .systemOrange : .secondaryLabelColor
        present(NSAttributedString(string: isFix ? "✎ " + text : text, attributes: [.font: font, .foregroundColor: color]),
                hint: Settings.keyAcceptAll?.display ?? "⇥", at: caret)
    }

    /// The selected emoji and its name, followed by the other matches; the next-word key cycles through them.
    func showEmoji(_ items: [Emoji.Item], selected: Int, at caret: NSRect) {
        let size = Overlay.fontSize(caret)
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: items[selected].char + " ", attributes: [.font: NSFont.systemFont(ofSize: size)]))
        s.append(NSAttributedString(string: items[selected].name, attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.8), .foregroundColor: NSColor.secondaryLabelColor]))
        let others = items.indices.filter { $0 != selected }.map { items[$0].char }
        if !others.isEmpty {
            s.append(NSAttributedString(string: "   " + others.joined(separator: " "), attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.8), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let accept = Settings.keyAcceptAll?.display ?? "⇥"
        let next = Settings.keyAcceptWord.map { " · \($0.display) next" } ?? ""
        present(s, hint: others.isEmpty ? accept : accept + next, at: caret)
    }

    private func present(_ text: NSAttributedString, hint hintText: String, at caret: NSRect) {
        label.attributedStringValue = text
        hint.stringValue = hintText
        label.sizeToFit()
        hint.sizeToFit()

        let padX: CGFloat = 5, gap: CGFloat = 6
        let w = padX + label.frame.width + gap + hint.frame.width + padX
        let h = max(label.frame.height, caret.height) + 2
        label.frame.origin = NSPoint(x: padX, y: (h - label.frame.height) / 2)
        hint.frame.origin = NSPoint(x: padX + label.frame.width + gap, y: (h - hint.frame.height) / 2)

        var origin = NSPoint(x: caret.maxX + 1, y: caret.minY - 1)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: caret.maxX, y: caret.midY)) }) ?? NSScreen.main {
            origin.x = min(origin.x, screen.visibleFrame.maxX - w)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
