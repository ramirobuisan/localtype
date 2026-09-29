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

    func show(_ text: String, at caret: NSRect, isFix: Bool = false) {
        let size = max(11, min(caret.height * 0.8, 20))
        label.font = .systemFont(ofSize: size)
        label.stringValue = isFix ? "✎ " + text : text
        label.textColor = isFix ? .systemOrange : .secondaryLabelColor
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
