import AppKit

/// A small numbered list under the text (alternative words, synonyms). Press 1–n to pick; Esc closes.
final class ChoicesPanel {
    private let panel: NSPanel
    private let stack = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private(set) var items: [String] = []
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        bg.layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 7, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
        ])
        panel.contentView = bg
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .tertiaryLabelColor
    }

    /// Shows `items` below `anchor` (Cocoa screen coordinates).
    func show(_ items: [String], heading: String, below anchor: NSRect) {
        self.items = items
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        title.stringValue = heading.uppercased()
        stack.addArrangedSubview(title)
        for (i, item) in items.enumerated() {
            let n = NSTextField(labelWithString: "\(i + 1)")
            n.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            n.textColor = .controlAccentColor
            let t = NSTextField(labelWithString: item.trimmingCharacters(in: .whitespaces))
            t.font = .systemFont(ofSize: 13)
            let row = NSStackView(views: [n, t]); row.spacing = 7
            stack.addArrangedSubview(row)
        }
        let size = stack.fittingSize
        var origin = NSPoint(x: anchor.minX - 9, y: anchor.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            if origin.y < screen.visibleFrame.minY { origin.y = anchor.maxY + 4 }   // no room below: show above
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil); items = [] }
}
