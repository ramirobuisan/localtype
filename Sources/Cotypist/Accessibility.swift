import AppKit
import ApplicationServices

struct FieldContext {
    let element: AXUIElement
    let prefix: String      // text before caret
    let caretRect: NSRect   // Cocoa screen coords (bottom-left origin)
    let lineHeight: CGFloat
    let bundleID: String?
    let appName: String?
}

enum AX {
    static func trusted(prompt: Bool) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v else { return nil }
        return (v as! AXUIElement)
    }

    /// Reads the focused text field. Returns nil for secure fields, selections, mid-line carets, etc.
    static func readContext() -> FieldContext? {
        guard let el = focusedElement() else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        let role: String? = attr(el, kAXRoleAttribute)
        let subrole: String? = attr(el, kAXSubroleAttribute)
        guard subrole != kAXSecureTextFieldSubrole else { return nil }
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole || role == "AXWebArea" || role == nil else { return nil }

        guard let value: String = attr(el, kAXValueAttribute) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 else { return nil }

        let ns = value as NSString
        let caret = range.location
        guard caret > 0, caret <= ns.length else { return nil }

        // Only complete at end of line (nothing but whitespace after caret on this line).
        let after = ns.substring(from: caret)
        let restOfLine = after.prefix { $0 != "\n" }
        guard Settings.completeInside || restOfLine.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }

        let prefix = ns.substring(to: caret)
        guard prefix.contains(where: { !$0.isWhitespace }) else { return nil }

        guard let (rect, h) = caretRect(el, caret: caret) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return FieldContext(element: el, prefix: String(prefix.suffix(1500)), caretRect: rect, lineHeight: h,
                            bundleID: app?.bundleIdentifier, appName: app?.localizedName)
    }

    /// Bounds of the character before the caret; its right edge is where the caret sits.
    private static func caretRect(_ el: AXUIElement, caret: Int) -> (NSRect, CGFloat)? {
        var r = CFRange(location: caret - 1, length: 1)
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let out else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.height > 0, rect.width >= 0 else { return nil }
        // Newline char before caret => caret is at start of a new line; not supported cleanly.
        let x = rect.maxX, yTop = rect.minY
        // AX coords: origin top-left of primary screen. Convert to Cocoa.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSRect(x: x, y: primaryH - yTop - rect.height, width: 0, height: rect.height)
        return (cocoa, rect.height)
    }
}
