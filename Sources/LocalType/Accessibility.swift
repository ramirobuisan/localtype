import AppKit
import ApplicationServices

struct FieldContext {
    let element: AXUIElement
    let prefix: String      // text before caret
    let caretRect: NSRect   // Cocoa screen coords (bottom-left origin)
    let lineHeight: CGFloat
    let bundleID: String?
    let appName: String?
    let pid: pid_t

    /// Caret position in global top-left coordinates (the space Accessibility and screen capture use).
    var caretPoint: CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: caretRect.minX, y: primaryH - caretRect.midY)
    }
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

        guard let (rect, h) = caretRect(el, caret: caret, text: ns) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return FieldContext(element: el, prefix: String(prefix.suffix(1500)), caretRect: rect, lineHeight: h,
                            bundleID: app?.bundleIdentifier, appName: app?.localizedName, pid: pid)
    }

    private static func bounds(_ el: AXUIElement, _ location: Int, _ length: Int) -> CGRect? {
        var r = CFRange(location: location, length: length)
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let out else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.height > 0, rect.width >= 0 else { return nil }
        return rect
    }

    /// Where the caret sits, as a zero-width rect in Cocoa coordinates, plus the line height.
    /// Normally the right edge of the character before the caret; right after a line break that character
    /// is on the previous line, so use the insertion point itself or the start of the next character.
    private static func caretRect(_ el: AXUIElement, caret: Int, text: NSString) -> (NSRect, CGFloat)? {
        let prev = text.character(at: caret - 1)
        let atLineStart = prev == 10 || prev == 13 || prev == 0x2028 || prev == 0x2029
        var x: CGFloat, top: CGFloat, height: CGFloat
        if !atLineStart {
            guard let r = bounds(el, caret - 1, 1) else { return nil }
            x = r.maxX; top = r.minY; height = r.height
        } else {
            let prevLine = bounds(el, caret - 1, 1)
            let isBelow = { (r: CGRect) in prevLine == nil || r.minY >= prevLine!.maxY - 1 }
            if let r = bounds(el, caret, 0), r.height > 0, isBelow(r) {
                x = r.minX; top = r.minY; height = r.height
            } else if caret < text.length, text.character(at: caret) != 10, let r = bounds(el, caret, 1), isBelow(r) {
                x = r.minX; top = r.minY; height = r.height
            } else if let r = bounds(el, caret, 0), let p = prevLine {
                // NSTextView (TextEdit, Mail…) reports an empty last line's insertion point at the left margin
                // but on the line above; the caret really is one line further down.
                x = r.minX; top = p.maxY; height = p.height
            } else {
                return nil   // empty last line and the app reports no insertion-point bounds
            }
        }
        // AX coords: origin top-left of primary screen. Convert to Cocoa.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSRect(x: x, y: primaryH - top - height, width: 0, height: height)
        return (cocoa, height)
    }
}
