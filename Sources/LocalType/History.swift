import CryptoKit
import Foundation

/// Local-only record of sentences you wrote, used to bias suggestions toward your own phrasing.
/// Stored encrypted (AES-GCM, key in the Keychain) in Application Support, file mode 600.
extension Notification.Name { static let historyChanged = Notification.Name("LocalTypeHistoryChanged") }

final class History {
    static let shared = History()

    struct Entry: Codable {
        let text: String
        let date: Date
        let app: String?   // bundle ID it was written in (nil in data from older builds)
    }
    /// What's stored (and synced): the entries, plus when each deleted text was deleted, so a deletion on one Mac
    /// also removes the text on the others instead of being re-added by the next merge.
    struct Store: Codable {
        var entries: [Entry]
        var deleted: [String: Date]
    }
    private(set) var entries: [Entry] = []
    private(set) var deleted: [String: Date] = [:]
    var store: Store { Store(entries: entries, deleted: deleted) }

    /// Short stable fingerprint of a text (tombstones never store the text itself).
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    private let url = AppPaths.support.appendingPathComponent("history.enc")
    private let legacyURL = AppPaths.support.appendingPathComponent("history.json")   // plain JSON, older builds
    private static let cap = 2000

    private init() {
        if let sealed = try? Data(contentsOf: url), let d = Vault.open(sealed) {
            if let s = try? JSONDecoder().decode(Store.self, from: d) { entries = s.entries; deleted = s.deleted }
            else if let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }   // before tombstones
        } else if let d = try? Data(contentsOf: legacyURL), let e = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = e          // move an older plain-text history into the encrypted file
            save()
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: legacyURL) }
        }
    }

    /// Merges other Macs' stores into this one (sync): union of entries, newest deletion per text wins over
    /// older copies of it. Returns how many entries were added or removed.
    @discardableResult
    func merge(_ others: [Store]) -> Int {
        var tomb = deleted
        for o in others { tomb.merge(o.deleted) { max($0, $1) } }
        var byText: [String: Entry] = [:]
        for e in entries + others.flatMap(\.entries) {
            if let old = byText[e.text], old.date <= e.date { continue }
            byText[e.text] = e
        }
        let merged = byText.values.filter { e in tomb[History.fingerprint(e.text)].map { e.date > $0 } ?? true }
            .sorted { $0.date < $1.date }.suffix(History.cap)
        let changed = abs(merged.count - entries.count) + Set(merged.map(\.text)).symmetricDifference(entries.map(\.text)).count / 2
        // Old tombstones aren't needed once every copy is gone; keep them 90 days.
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        deleted = tomb.filter { $0.value > cutoff }
        entries = Array(merged)
        save(notify: false)   // a merge isn't a local change: don't schedule another sync
        return changed
    }

    var count: Int { entries.count }
    func count(app: String) -> Int { entries.filter { $0.app == app }.count }

    private func tombstone(_ list: [Entry]) { let now = Date(); for e in list { deleted[History.fingerprint(e.text)] = now } }
    func deleteAll() { tombstone(entries); entries = []; save() }
    func delete(app: String) { tombstone(entries.filter { $0.app == app }); entries.removeAll { $0.app == app }; save() }
    func delete(_ entry: Entry) {
        tombstone([entry])
        entries.removeAll { $0.text == entry.text && $0.date == entry.date }
        save()
    }

    private func save(notify: Bool = true) {
        guard let d = try? JSONEncoder().encode(store), let sealed = Vault.seal(d) else { return }
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if notify { NotificationCenter.default.post(name: .historyChanged, object: nil) }
    }

    func add(_ text: String, app: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 15, t.count <= 300, entries.last?.text != t, !entries.contains(where: { $0.text == t }) else { return }
        entries.append(Entry(text: t, date: Date(), app: app))
        if entries.count > History.cap { entries.removeFirst(entries.count - History.cap) }
        save()
    }

    /// Last sentence of `text` (text after the final . ! ? or newline).
    static func lastSentence(_ text: String, completed: Bool) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        var end = ""
        if completed {
            guard let l = t.last, ".!?".contains(l) else { return nil }
            end = String(t.removeLast())   // keep "?" and "!" as written
        }
        let start = t.lastIndex(where: { ".!?\n".contains($0) }).map { t.index(after: $0) } ?? t.startIndex
        let s = String(t[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s + end
    }

    /// The last finished sentence in `text` (ending in . ! or ?), even if more text follows it.
    static func lastCompletedSentence(_ text: String) -> String? {
        guard let end = text.lastIndex(where: { ".!?".contains($0) }) else { return nil }
        return lastSentence(String(text[...end]), completed: true)
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
