import Foundation

/// Emoji completion: typing ":" and part of a name (":fire", ":thumbs_up") suggests matching emoji.
/// Names come from the Unicode character database in the Swift standard library, so no data file is needed.
enum Emoji {
    struct Item { let char: String; let name: String; let words: [String] }

    static let all: [Item] = {
        var ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x2300...0x23FF,
                                             0x2190...0x21FF, 0x1F000...0x1F2FF]
        ranges += [0x203C...0x203C, 0x2049...0x2049, 0x2122...0x2122, 0x2139...0x2139, 0x3030...0x3030, 0x303D...0x303D]
        var out: [Item] = []
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v) else { continue }
                let p = s.properties
                guard p.isEmoji, !p.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(v), let name = p.name?.lowercased() else { continue }
                // Text-default emoji need VS16 to render as color emoji.
                let char = p.isEmojiPresentation ? String(s) : String(s) + "\u{FE0F}"
                out.append(Item(char: char, name: name, words: name.split { $0 == " " || $0 == "-" }.map(String.init)))
            }
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

    /// The ":query" right before the caret, if any. The colon must start the text or follow a space or bracket,
    /// so times ("10:30"), URLs and "Note:" don't trigger it.
    static func query(in prefix: String) -> String? {
        var q = ""
        for ch in prefix.reversed() {
            if ch == ":" {
                guard q.count >= 2, q.count <= 30 else { return nil }
                let before = prefix.dropLast(q.count + 1).last
                guard before == nil || before!.isWhitespace || "([{\"'“‘".contains(before!) else { return nil }
                return String(q.reversed()).lowercased()
            }
            guard ch.isLetter || ch.isNumber || "_+-".contains(ch) else { return nil }
            q.append(ch)
        }
        return nil
    }

    /// Best matches for a query, most likely first.
    static func search(_ query: String, limit: Int = 5) -> [Item] {
        let tokens = query.split(separator: "_").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let usage = Settings.emojiUsage
        var scored: [(Double, Item)] = []
        for item in all {
            var used = Set<Int>()
            var score = 100.0
            for t in tokens {
                guard let i = item.words.indices.first(where: { !used.contains($0) && item.words[$0].hasPrefix(t) }) else { score = -1; break }
                used.insert(i)
                score -= Double(i) * 3
                if item.words[i] == t { score += 15 }
            }
            guard score > 0 else { continue }
            score -= Double(item.words.count) * 2
            score += Double(min(usage[item.char] ?? 0, 10)) * 4
            scored.append((score, item))
        }
        // Shortcodes: an exact one wins outright; a partial one (":sm" → smile) still ranks above name matches.
        for (code, char) in aliases where code.hasPrefix(query) {
            let item = all.first { $0.char == char } ?? Item(char: char, name: code, words: [code])
            scored.removeAll { $0.1.char == char }
            scored.append((code == query ? 1_000 : 500 - Double(code.count), item))
        }
        scored.sort { $0.0 > $1.0 || ($0.0 == $1.0 && $0.1.name < $1.1.name) }
        var seen = Set<String>(), out: [Item] = []
        for (_, item) in scored where out.count < limit && seen.insert(item.char).inserted { out.append(item) }
        return out
    }

    static func recordUse(_ char: String) {
        var u = Settings.emojiUsage
        u[char, default: 0] += 1
        Settings.emojiUsage = u
    }
}
