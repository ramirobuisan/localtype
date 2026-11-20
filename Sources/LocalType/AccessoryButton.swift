import AppKit

/// Optional floating button at the corner of the text field you're typing in; clicking it opens LocalType's
/// menu right there (turn completions off for this app or site, Settings…). It follows the focused field and
/// hides when the focus isn't in a text field where LocalType works.
final class AccessoryButton {
    static let shared = AccessoryButton()

    /// Shows the menu at a screen point (set by the app delegate, which owns the menu).
    var openMenu: ((NSPoint) -> Void)?

    private let panel: NSPanel
    private var timer: Timer?
    private static let size: CGFloat = 22

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let b = NSButton(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        b.bezelStyle = .circular
        b.isBordered = true
        b.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "LocalType menu")
        b.imagePosition = .imageOnly
        b.toolTip = "LocalType"
        b.target = self
        b.action = #selector(clicked(_:))
        panel.contentView = b
    }

    /// Starts or stops following the focused field according to the setting.
    func update() {
        if Settings.showAccessoryButton && Settings.enabled {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.follow() }
            }
            follow()
        } else {
            timer?.invalidate(); timer = nil
            panel.orderOut(nil)
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        openMenu?(NSPoint(x: panel.frame.minX, y: panel.frame.minY - 4))
    }

    /// Places the button inside the top-right corner of the focused editable text field.
    private func follow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let el = AX.focusedElement(ofApp: app.processIdentifier),
              let frame = AX.editableTextFrame(el),
              Settings.allowed(bundleID: app.bundleIdentifier, domain: AX.webDomain(of: el)),
              frame.width >= 80, frame.height >= 16 else {
            panel.orderOut(nil); return
        }
        let s = Self.size
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // AX frames are top-left based; Cocoa windows bottom-left.
        let x = frame.maxX - s - 4
        let y = primaryH - frame.minY - s - min(4, max(0, (frame.height - s) / 2))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}
