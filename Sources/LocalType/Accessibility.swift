import AppKit
import ApplicationServices

/// The look of the text in a field, for drawing suggestions that blend in.
struct TextStyle {
    let font: NSFont
    let color: NSColor?
}

struct FieldContext {
    let element: AXUIElement
    let prefix: String      // text before caret
    let caretRect: NSRect   // Cocoa screen coords (bottom-left origin)
    let lineHeight: CGFloat
    let bundleID: String?
    let appName: String?
    let pid: pid_t
    /// Website host when the field is inside a web page (any browser), for per-website rules.
    let domain: String?
    let caretIndex: Int
    let style: TextStyle?
    /// Text follows the caret on the same line (only with "complete inside existing text").
    let hasTextAfter: Bool
    /// Right edge (Cocoa x) of that following text, so a suggestion's backing can hide all of it.
    let textAfterMaxX: CGFloat?
    /// The "Try it" box in LocalType's own Setup window (read directly, never recorded).
    var isPractice = false

    /// Where the person is writing, for the prompt: the app, plus the website when it's a web page
    /// ("Google Chrome on github.com"). Web-based apps that are the site itself (Discord) stay just the app.
    var place: String? {
        guard let domain else { return appName }
        guard let app = appName else { return domain }
        let labels = domain.split(separator: ".")
        let site = labels.count >= 2 ? labels[labels.count - 2] : labels.first ?? ""
        // Exact match only: "Google Chrome" on docs.google.com must keep the site.
        return app.lowercased().replacingOccurrences(of: " ", with: "") == site ? app : "\(app) on \(domain)"
    }

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
    /// `element` defaults to the system-wide focused element (the self-test passes one app's focused field).
    static func readContext(element: AXUIElement? = nil) -> FieldContext? {
        // LocalType's own windows are never queried through Accessibility: the request would be answered by this
        // same main thread, which is busy waiting for it (a freeze of several seconds).
        if element == nil, NSApp.isActive { return ownContext() }
        guard let el = element ?? focusedElement() else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        let role: String? = attr(el, kAXRoleAttribute)
        let subrole: String? = attr(el, kAXSubroleAttribute)
        guard subrole != kAXSecureTextFieldSubrole else { return nil }
        // Search fields take queries, not prose, and often use Tab to move on.
        guard subrole != "AXSearchField" else { return nil }
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

        // Rich web editors (Discord, Slack…) keep zero-width characters in "empty" fields; they aren't text.
        let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        let prefix = ns.substring(to: caret).filter { !invisible.contains($0) }
        guard prefix.contains(where: { !$0.isWhitespace }) else { return nil }

        guard let (rect, h) = caretRect(el, caret: caret, text: ns) ?? markerCaretRect(el) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return FieldContext(element: el, prefix: String(prefix.suffix(1500)), caretRect: rect, lineHeight: h,
                            bundleID: app?.bundleIdentifier, appName: app?.localizedName, pid: pid, domain: webDomain(of: el),
                            caretIndex: caret, style: textStyle(el, at: caret - 1),
                            hasTextAfter: !restOfLine.allSatisfy({ $0 == " " || $0 == "\t" }),
                            textAfterMaxX: restOfLine.isEmpty ? nil
                                : screenRect(el, location: caret, length: (String(restOfLine) as NSString).length)?.maxX)
    }

    /// Host of the web page containing `el`: walks up to the AXWebArea and reads its URL (http/https only).
    static func webDomain(of el: AXUIElement) -> String? {
        var cur: AXUIElement? = el
        for _ in 0..<40 {
            guard let e = cur else { return nil }
            if (attr(e, kAXRoleAttribute) as String?) == "AXWebArea" {
                guard let url: URL = attr(e, kAXURLAttribute), let scheme = url.scheme, scheme.hasPrefix("http"),
                      var host = url.host?.lowercased() else { return nil }
                if host.hasPrefix("www.") { host.removeFirst(4) }
                return host
            }
            cur = attr(e, kAXParentAttribute)
        }
        return nil
    }

    /// Font and color of the character at `index`, from the field's attributed string.
    static func textStyle(_ el: AXUIElement, at index: Int) -> TextStyle? {
        var r = CFRange(location: max(0, index), length: 1)
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let s = out as! NSAttributedString?, s.length > 0 else { return nil }
        let attrs = s.attributes(at: 0, effectiveRange: nil)
        guard let f = attrs[NSAttributedString.Key("AXFont")] as? [String: Any],
              let size = (f["AXFontSize"] as? NSNumber).map({ CGFloat(truncating: $0) }), size > 4 else { return nil }
        let font = (f["AXFontName"] as? String).flatMap { NSFont(name: $0, size: size) }
            ?? (f["AXFontFamily"] as? String).flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        let fg = attrs[NSAttributedString.Key("AXForegroundColor")]
        let color = fg.flatMap { CFGetTypeID($0 as CFTypeRef) == CGColor.typeID ? NSColor(cgColor: $0 as! CGColor) : nil }
        return TextStyle(font: font, color: color)
    }

    /// Screen rect (Cocoa coordinates) of a range of the field's text.
    static func screenRect(_ el: AXUIElement, location: Int, length: Int) -> NSRect? {
        guard let r = bounds(el, location, length) else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    /// Caret position through the text-marker API (Chromium/WebKit). Rich editors in web and Electron apps
    /// (Discord, Slack, Notion…) often return an empty rect for AXBoundsForRange but a real one here.
    private static func markerCaretRect(_ el: AXUIElement) -> (NSRect, CGFloat)? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &range) == .success, let range else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, range, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &r), r.height > 0, r.origin != .zero else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // A collapsed range: its left edge is the caret.
        return (NSRect(x: r.minX, y: primaryH - r.minY - r.height, width: 0, height: r.height), r.height)
    }

    /// Chromium and Electron apps (Chrome, Slack, Discord, VS Code, Obsidian…) only build their accessibility tree
    /// once an assistive tool asks for it. Setting AXManualAccessibility does that; other apps ignore the attribute.
    private static var accessibilityRequested = Set<pid_t>()
    static func enableAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier, accessibilityRequested.insert(pid).inserted else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Frame (AX coordinates) of an element if it's an editable text field LocalType could work in.
    static func editableTextFrame(_ el: AXUIElement) -> CGRect? {
        let role: String? = attr(el, kAXRoleAttribute), subrole: String? = attr(el, kAXSubroleAttribute)
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole,
              subrole != kAXSecureTextFieldSubrole, subrole != "AXSearchField" else { return nil }
        var editable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &editable) == .success, !editable.boolValue { return nil }
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Identifier of the "Try it" text box in the Setup window, the only own field that gets suggestions.
    static let practiceID = NSUserInterfaceItemIdentifier("localtype.practice")

    /// The practice box, read straight from the text view.
    static func ownContext(_ textView: NSTextView? = nil) -> FieldContext? {
        guard let tv = textView ?? NSApp.keyWindow?.firstResponder as? NSTextView, tv.identifier == practiceID else { return nil }
        let sel = tv.selectedRange()
        guard sel.length == 0, sel.location > 0 else { return nil }
        let ns = tv.string as NSString
        let restOfLine = ns.substring(from: sel.location).prefix { $0 != "\n" }
        guard Settings.completeInside || restOfLine.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        let prefix = ns.substring(to: sel.location)
        guard prefix.contains(where: { !$0.isWhitespace }) else { return nil }
        let rect = tv.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: nil)
        guard rect.height > 0 else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return FieldContext(element: AXUIElementCreateApplication(me), prefix: String(prefix.suffix(1500)),
                            caretRect: NSRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height), lineHeight: rect.height,
                            bundleID: Bundle.main.bundleIdentifier, appName: "LocalType", pid: me, domain: nil,
                            caretIndex: sel.location, style: TextStyle(font: tv.font ?? .systemFont(ofSize: 13), color: tv.textColor),
                            hasTextAfter: !restOfLine.allSatisfy({ $0 == " " || $0 == "\t" }), textAfterMaxX: nil, isPractice: true)
    }

    struct Selection {
        let element: AXUIElement
        let text: String
        let rect: NSRect       // Cocoa coordinates
        let before: String     // context around it, for the model
        let after: String
    }

    /// A short selection (a word or phrase, up to 4 words) in an editable text field, for synonyms.
    static func readSelection() -> Selection? {
        guard !NSApp.isActive, let el = focusedElement() else { return nil }   // never our own windows (see readContext)
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let role: String? = attr(el, kAXRoleAttribute), subrole: String? = attr(el, kAXSubroleAttribute)
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole,
              subrole != kAXSecureTextFieldSubrole, subrole != "AXSearchField",
              let value: String = attr(el, kAXValueAttribute), let rv: AXValue = attr(el, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv, .cfRange, &range), range.length > 0, range.length <= 40 else { return nil }
        let ns = value as NSString
        guard range.location + range.length <= ns.length else { return nil }
        let text = ns.substring(with: NSRange(location: range.location, length: range.length)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("\n"), text.split(separator: " ").count <= 4, text.contains(where: \.isLetter),
              let rect = screenRect(el, location: range.location, length: range.length) else { return nil }
        let beforeStart = max(0, range.location - 200), afterEnd = min(ns.length, range.location + range.length + 120)
        return Selection(element: el, text: text, rect: rect,
                         before: ns.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
                         after: ns.substring(with: NSRange(location: range.location + range.length, length: afterEnd - range.location - range.length)))
    }

    /// The focused element of a given app (works while our own menu is open).
    static func focusedElement(ofApp pid: pid_t) -> AXUIElement? {
        attr(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
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
