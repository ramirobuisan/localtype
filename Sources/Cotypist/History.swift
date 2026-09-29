import Foundation

/// Local-only record of sentences you wrote, used to bias suggestions toward your own phrasing.
/// Stored as JSON in Application Support (file mode 600). Not encrypted.
final class History {
    static let shared = History()

    private struct Entry: Codable { let text: String; let date: Date }
    private var entries: [Entry] = []
    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Cotypist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    private static let cap = 2000

    private init() {
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    var count: Int { entries.count }

    func deleteAll() { entries = []; save() }

    private func save() {
        guard let d = try? JSONEncoder().encode(entries) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 15, t.count <= 300, entries.last?.text != t, !entries.contains(where: { $0.text == t }) else { return }
        entries.append(Entry(text: t, date: Date()))
        if entries.count > History.cap { entries.removeFirst(entries.count - History.cap) }
        save()
    }

    /// Last sentence of `text` (text after the final . ! ? or newline).
    static func lastSentence(_ text: String, completed: Bool) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if completed {
            guard let l = t.last, ".!?".contains(l) else { return nil }
            t.removeLast()
        }
        let start = t.lastIndex(where: { ".!?\n".contains($0) }).map { t.index(after: $0) } ?? t.startIndex
        let s = String(t[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s + (completed ? "." : "")
    }

    /// Past sentences sharing words with what's being typed, most relevant first.
    func relevant(to prefix: String, limit: Int) -> [String] {
        guard limit > 0, !entries.isEmpty else { return [] }
        let words = Set(prefix.lowercased().split { !$0.isLetter }.suffix(8).map(String.init).filter { $0.count > 3 })
        var scored: [(Int, Int, String)] = []
        for (i, e) in entries.enumerated() {
            let ew = Set(e.text.lowercased().split { !$0.isLetter }.map(String.init))
            let score = words.intersection(ew).count
            if score > 0 { scored.append((score, i, e.text)) }
        }
        scored.sort { ($0.0, $0.1) > ($1.0, $1.1) }
        return scored.prefix(limit).map { $0.2 }
    }
}
