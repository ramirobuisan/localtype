import AppKit

/// A key + modifiers combo, stored as "code|flags|label".
struct Shortcut: Equatable {
    var code: Int
    var flags: UInt        // NSEvent.ModifierFlags raw, device-independent, limited to ⌘⌃⌥⇧
    var label: String

    static let mask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var string: String { "\(code)|\(flags)|\(label)" }
    init(code: Int, flags: NSEvent.ModifierFlags, label: String) {
        self.code = code; self.flags = flags.intersection(Shortcut.mask).rawValue; self.label = label
    }
    init?(_ s: String) {
        let p = s.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard p.count == 3, let c = Int(p[0]), let f = UInt(p[1]) else { return nil }
        code = c; flags = f; label = String(p[2])
    }

    var display: String {
        var m = ""
        let f = NSEvent.ModifierFlags(rawValue: flags)
        if f.contains(.control) { m += "⌃" }
        if f.contains(.option) { m += "⌥" }
        if f.contains(.shift) { m += "⇧" }
        if f.contains(.command) { m += "⌘" }
        return m + label
    }

    func matches(code c: Int64, cgFlags: CGEventFlags) -> Bool {
        var f: UInt = 0
        if cgFlags.contains(.maskControl) { f |= NSEvent.ModifierFlags.control.rawValue }
        if cgFlags.contains(.maskAlternate) { f |= NSEvent.ModifierFlags.option.rawValue }
        if cgFlags.contains(.maskShift) { f |= NSEvent.ModifierFlags.shift.rawValue }
        if cgFlags.contains(.maskCommand) { f |= NSEvent.ModifierFlags.command.rawValue }
        return Int(c) == code && f == flags
    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 48: return "⇥"
        case 49: return "Space"
        case 36, 76: return "↩"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// Click, press a combo, done. Esc cancels, ⌫ clears.
final class ShortcutRecorder: NSButton {
    static var isRecording = false
    var value: Shortcut? { didSet { refresh() } }
    var onChange: ((Shortcut?) -> Void)?
    private var monitor: Any?

    convenience init() {
        self.init(title: "", target: nil, action: nil)
        bezelStyle = .rounded
        target = self; action = #selector(toggle)
        widthAnchor.constraint(equalToConstant: 150).isActive = true
    }

    private func refresh() { title = value?.display ?? "Record Shortcut" }

    @objc private func toggle() {
        if monitor != nil { stop(); return }
        title = "Press keys…"
        ShortcutRecorder.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.stop(); return nil }                    // Esc: cancel
            if e.keyCode == 51, e.modifierFlags.intersection(Shortcut.mask).isEmpty {  // ⌫: clear
                self.value = nil; self.onChange?(nil); self.stop(); return nil
            }
            let s = Shortcut(code: Int(e.keyCode), flags: e.modifierFlags, label: Shortcut.label(for: e))
            self.value = s; self.onChange?(s); self.stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        ShortcutRecorder.isRecording = false
        refresh()
    }
}
