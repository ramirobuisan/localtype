import Foundation

/// Emoji completion: ":" and part of a name (":fire", ":thumbs_up", ":fire:") suggests matching emoji, a lone " :"
/// suggests the ones you use most, and text emoticons (":-)", "<3") can turn into emoji. Names come from the Unicode
/// character database in the Swift standard library, so no data file is needed.
enum Emoji {
    /// What the overlay shows and what gets typed: `char` already has the preferred skin tone and gender applied.
    struct Item { let char: String; let name: String; let words: [String] }

    /// A base emoji before styling.
    private struct Entry {
        let scalar: Unicode.Scalar?
        let base: String           // as typed with no preferences (VS16 added where needed)
        let name: String
        let words: [String]
        let toneable: Bool         // takes a skin-tone modifier
        let genderable: Bool       // takes a ZWJ ♀/♂ sign ("police officer" → "woman police officer")
        let role: String?          // profession: person + ZWJ + this object
    }

    private static func words(_ name: String) -> [String] { name.split { $0 == " " || $0 == "-" }.map(String.init) }

    /// Person emoji that have woman / man variants made with a ZWJ gender sign.
    private static let genderable: Set<UInt32> = [
        0x1F46E, 0x1F575, 0x1F482, 0x1F477, 0x1F64B, 0x1F646, 0x1F645, 0x1F937, 0x1F926, 0x1F481, 0x1F647, 0x1F9CF,
        0x1F64E, 0x1F64D, 0x1F486, 0x1F487, 0x1F6B6, 0x1F3C3, 0x1F9CD, 0x1F9CE, 0x1F3C4, 0x1F3CA, 0x1F6B4, 0x1F9D8,
        0x1F9D9, 0x1F9DA, 0x1F9DB, 0x1F9DC, 0x1F9DD, 0x1F9DE, 0x1F9DF, 0x1F9B8, 0x1F9B9, 0x1F3CB, 0x26F9, 0x1F938,
        0x1F93D, 0x1F93E, 0x1F939, 0x1F6A3, 0x1F9D1,
    ]

    /// Professions: 🧑 / 👩 / 👨 + ZWJ + object.
    private static let professions: [(String, String)] = [
        ("health worker", "\u{2695}\u{FE0F}"), ("student", "🎓"), ("teacher", "🏫"), ("judge", "\u{2696}\u{FE0F}"),
        ("farmer", "🌾"), ("cook", "🍳"), ("mechanic", "🔧"), ("factory worker", "🏭"), ("office worker", "💼"),
        ("scientist", "🔬"), ("technologist", "💻"), ("singer", "🎤"), ("artist", "🎨"), ("pilot", "\u{2708}\u{FE0F}"),
        ("astronaut", "🚀"), ("firefighter", "🚒"),
    ]

    private static let entries: [Entry] = {
        var ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x2300...0x23FF,
                                             0x2190...0x21FF, 0x1F000...0x1F2FF]
        ranges += [0x203C...0x203C, 0x2049...0x2049, 0x2122...0x2122, 0x2139...0x2139, 0x3030...0x3030, 0x303D...0x303D]
        var out: [Entry] = []
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v) else { continue }
                let p = s.properties
                guard p.isEmoji, !p.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(v), let name = p.name?.lowercased() else { continue }
                // Text-default emoji need VS16 to render as color emoji.
                let base = p.isEmojiPresentation ? String(s) : String(s) + "\u{FE0F}"
                out.append(Entry(scalar: s, base: base, name: name, words: words(name), toneable: p.isEmojiModifierBase,
                                 genderable: genderable.contains(v), role: nil))
            }
        }
        for (name, object) in professions {
            out.append(Entry(scalar: nil, base: "🧑\u{200D}" + object, name: name, words: words(name),
                             toneable: true, genderable: false, role: object))
        }
        return out
    }()

    /// Common shortcodes whose Unicode names differ from what people type.
    private static let aliases: [String: String] = [
        "smile": "😄", "joy": "😂", "lol": "😂", "laughing": "😆", "heart": "❤️", "love": "😍", "thumbsup": "👍", "+1": "👍",
        "thumbsdown": "👎", "-1": "👎", "ok": "👌", "tada": "🎉", "party": "🥳", "fire": "🔥", "rocket": "🚀", "eyes": "👀",
        "wave": "👋", "pray": "🙏", "clap": "👏", "100": "💯", "sob": "😭", "cry": "😢", "thinking": "🤔", "shrug": "🤷",
        "wink": "😉", "check": "✅", "x": "❌", "warning": "⚠️", "star": "⭐", "sparkles": "✨", "muscle": "💪",
        "sunglasses": "😎", "cool": "😎", "angry": "😠", "skull": "💀", "facepalm": "🤦", "kiss": "😘", "hug": "🤗",
        "coffee": "☕", "beer": "🍺", "sad": "😞", "happy": "😊", "blush": "😊", "grin": "😁", "sweat_smile": "😅",
        "upside_down": "🙃", "rofl": "🤣", "heart_eyes": "😍", "zzz": "💤", "poop": "💩", "money": "💰", "bug": "🐛", "red_heart": "❤️",
    ]

    /// Text emoticons and their emoji, longest first so ":-)" wins over ":)".
    private static let emoticons: [(String, String)] = [
        (">:-(", "😠"), (">:(", "😠"), (":'-(", "😢"), (":'(", "😢"), (":')", "🥲"), ("</3", "💔"), ("B-)", "😎"),
        (":-)", "🙂"), (";-)", "😉"), (":-(", "🙁"), (":-D", "😃"), (":-P", "😛"), (":-p", "😛"), (":-O", "😮"),
        (":-o", "😮"), (":-/", "😕"), (":-|", "😐"), (":-*", "😘"), ("^_^", "😊"), ("o_O", "😳"), ("O_o", "😳"),
        (":)", "🙂"), (";)", "😉"), (":(", "🙁"), (":D", "😃"), ("xD", "😆"), ("XD", "😆"), (":P", "😛"), (":p", "😛"),
        (";P", "😜"), (";p", "😜"), (":O", "😮"), (":o", "😮"), (":/", "😕"), (":|", "😐"), (":*", "😘"), ("<3", "❤️"),
        ("^^", "😊"), (":3", "😺"),
    ]

    /// Shown for a lone " :" until you have favorites of your own.
    private static let defaults = ["😊", "👍", "❤️", "😂", "🙏", "🎉", "🔥", "😅"]

    // MARK: Styling

    private static func render(_ e: Entry) -> [Item] {
        let tone = Settings.emojiSkinTone, gender = Settings.emojiGender
        func styled(tone t: Int) -> Item {
            let mod = t > 0 && e.toneable ? String(Unicode.Scalar(0x1F3FA + UInt32(t))!) : ""
            if let role = e.role {
                let person = gender == 1 ? "👩" : gender == 2 ? "👨" : "🧑"
                let prefix = gender == 1 ? "woman " : gender == 2 ? "man " : ""
                return Item(char: person + mod + "\u{200D}" + role, name: prefix + e.name, words: e.words)
            }
            var char = e.base, name = e.name
            if !mod.isEmpty, let s = e.scalar { char = String(s) + mod }
            if e.genderable, gender != 0 {
                char += "\u{200D}" + (gender == 1 ? "\u{2640}\u{FE0F}" : "\u{2642}\u{FE0F}")
                name = (gender == 1 ? "woman " : "man ") + name
            }
            return Item(char: char, name: name, words: e.words)
        }
        var out = [styled(tone: tone)]
        if tone > 0, e.toneable, Settings.emojiIncludeNeutral { out.append(styled(tone: 0)) }
        return out
    }

    /// Renders a plain emoji with the preferences when it's one we know (for aliases and emoticons).
    private static func styledChar(_ plain: String) -> Item? {
        entries.first { $0.base == plain || ($0.scalar.map { String($0) } == plain) }.flatMap { render($0).first }
    }

    // MARK: Detection

    /// The ":query" right before the caret and how many characters it spans (to delete on accept).
    /// The colon must start the text or follow a space or bracket, so times ("10:30"), URLs and "Note:" don't trigger it.
    /// A closing colon (":fire:") is allowed; a lone " :" (after a space) gives an empty query.
    static func query(in prefix: String) -> (query: String, length: Int)? {
        var text = Substring(prefix), closing = 0
        if text.hasSuffix(":"), text.dropLast().last.map({ $0.isLetter || $0.isNumber || $0 == "_" }) == true {
            text = text.dropLast(); closing = 1
        }
        var q = ""
        for ch in text.reversed() {
            if ch == ":" {
                let before = text.dropLast(q.count + 1).last
                if q.isEmpty {
                    // Lone " :": only right after a space, never at the start of a field or after a word.
                    guard closing == 0, let b = before, b == " " else { return nil }
                    return ("", 1)
                }
                guard q.count >= 2, q.count <= 30 else { return nil }
                guard before == nil || before!.isWhitespace || "([{\"'“‘".contains(before!) else { return nil }
                return (String(q.reversed()).lowercased(), q.count + 1 + closing)
            }
            guard ch.isLetter || ch.isNumber || "_+-".contains(ch) else { return nil }
            q.append(ch)
        }
        return nil
    }

    /// The emoticon right before the caret, if it stands on its own, and its length.
    static func emoticon(in prefix: String) -> (item: Item, length: Int)? {
        for (text, plain) in emoticons where prefix.hasSuffix(text) {
            let before = prefix.dropLast(text.count).last
            guard before == nil || before!.isWhitespace else { continue }
            let item = styledChar(plain) ?? Item(char: plain, name: text, words: [])
            return (Item(char: item.char, name: text, words: []), text.count)
        }
        return nil
    }

    // MARK: Search

    /// Best matches for a query, most likely first; an empty query gives your most-used emoji.
    static func search(_ query: String, limit: Int = 5) -> [Item] {
        let usage = Settings.emojiUsage
        if query.isEmpty {
            var picks = usage.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)
            for d in defaults where !picks.contains(d) { picks.append(d) }
            return picks.prefix(limit).map { char in
                styledChar(char) ?? Item(char: char, name: entries.first { $0.base == char }?.name ?? "", words: [])
            }
        }
        let tokens = query.split(separator: "_").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(Double, Entry)] = []
        for e in entries {
            var used = Set<Int>()
            var score = 100.0
            for t in tokens {
                guard let i = e.words.indices.first(where: { !used.contains($0) && e.words[$0].hasPrefix(t) }) else { score = -1; break }
                used.insert(i)
                score -= Double(i) * 3
                if e.words[i] == t { score += 15 }
            }
            guard score > 0 else { continue }
            score -= Double(e.words.count) * 2
            score += Double(min(usage[render(e)[0].char] ?? 0, 10)) * 4
            scored.append((score, e))
        }
        // Shortcodes: an exact one wins outright; a partial one (":sm" → smile) still ranks above name matches.
        for (code, char) in aliases where code.hasPrefix(query) {
            let e = entries.first { $0.base == char }
                ?? Entry(scalar: nil, base: char, name: code, words: [code], toneable: false, genderable: false, role: nil)
            scored.removeAll { $0.1.base == char }
            scored.append((code == query ? 1_000 : 500 - Double(code.count), e))
        }
        scored.sort { $0.0 > $1.0 || ($0.0 == $1.0 && $0.1.name < $1.1.name) }
        var seen = Set<String>(), out: [Item] = []
        for (_, e) in scored {
            for item in render(e) where out.count < limit && seen.insert(item.char).inserted { out.append(item) }
            if out.count >= limit { break }
        }
        return out
    }

    static func recordUse(_ char: String) {
        var u = Settings.emojiUsage
        u[char, default: 0] += 1
        Settings.emojiUsage = u
    }
}
