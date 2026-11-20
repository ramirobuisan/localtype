import CommonCrypto
import CryptoKit
import Foundation

/// Syncs the typing history between your Macs through iCloud Drive, end-to-end encrypted.
///
/// Each Mac writes its own encrypted file (iCloud Drive/LocalType/history-<device>.lthist) and merges the others'.
/// The key is derived from a sync passphrase you enter on each Mac (PBKDF2-SHA256); the passphrase is never stored
/// and the key stays in this Mac's Keychain, so Apple only ever sees encrypted files.
enum Sync {
    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }
    static var available: Bool { FileManager.default.fileExists(atPath: iCloudDrive.path) }

    /// The folder used for sync (`override` lets the self-test use a scratch folder).
    static var override: URL?
    static var folder: URL? {
        let dir = override ?? (available ? iCloudDrive.appendingPathComponent("LocalType", isDirectory: true) : nil)
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "syncDeviceID") { return id }
        let id = UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(id, forKey: "syncDeviceID")
        return String(id)
    }

    /// PBKDF2-SHA256, 210 000 rounds, fixed app salt (the same passphrase must give the same key on every Mac).
    static func deriveKey(_ passphrase: String) -> SymmetricKey? {
        let salt = Array("LocalType typing-history sync v1".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let rc = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count, salt, salt.count,
                                      CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000, &out, out.count)
        return rc == kCCSuccess ? SymmetricKey(data: out) : nil
    }

    /// Stores the key for a new passphrase. Files written with a different passphrase can't be read afterwards.
    static func setPassphrase(_ passphrase: String) -> Bool {
        guard passphrase.count >= 8, let key = deriveKey(passphrase) else { return false }
        Vault.setSyncKey(key)
        return true
    }

    enum Result { case ok(added: Int, macs: Int), failed(String) }

    /// Writes this Mac's history and merges the other Macs' files.
    static func run(key: SymmetricKey? = Vault.syncKey) -> Result {
        guard let folder else { return .failed("iCloud Drive isn't turned on for this Mac.") }
        guard let key else { return .failed("Set a sync passphrase first.") }
        let fm = FileManager.default
        // Merge first, so this Mac's file also carries what it just learned.
        var others: [History.Store] = [], unreadable = 0
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("history-") && !f.lastPathComponent.contains(deviceID) {
            if f.pathExtension == "icloud" {   // not downloaded yet: ask iCloud for it, pick it up next time
                try? fm.startDownloadingUbiquitousItem(at: f)
                continue
            }
            guard f.pathExtension == "lthist", let sealed = try? Data(contentsOf: f) else { continue }
            guard let d = Vault.open(sealed, with: key), let store = try? JSONDecoder().decode(History.Store.self, from: d) else {
                unreadable += 1; continue
            }
            others.append(store)
        }
        let changed = History.shared.merge(others)
        guard let d = try? JSONEncoder().encode(History.shared.store), let sealed = Vault.seal(d, with: key) else {
            return .failed("Couldn't encrypt the history.")
        }
        do { try sealed.write(to: folder.appendingPathComponent("history-\(deviceID).lthist"), options: .atomic) }
        catch { return .failed("Couldn't write to iCloud Drive: \(error.localizedDescription)") }
        UserDefaults.standard.set(Date(), forKey: "lastSync")
        if unreadable > 0 { return .failed("\(unreadable) Mac(s) use a different sync passphrase; their history was skipped.") }
        return .ok(added: changed, macs: others.count + 1)
    }

    static var lastSync: Date? { UserDefaults.standard.object(forKey: "lastSync") as? Date }

    // MARK: Schedule

    private static var timer: Timer?
    private static var pending: DispatchWorkItem?
    private static var observer: NSObjectProtocol?

    /// Starts or stops automatic sync (at launch, every 10 minutes, and shortly after the history changes).
    static func update() {
        guard Settings.syncHistory, Settings.recordWriting, Vault.syncKey != nil else {
            timer?.invalidate(); timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in runInBackground() }
            observer = NotificationCenter.default.addObserver(forName: .historyChanged, object: nil, queue: .main) { _ in
                pending?.cancel()
                let w = DispatchWorkItem { runInBackground() }
                pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
            }
        }
        runInBackground()
    }

    /// History is main-thread confined; the work is small (a few hundred KB at most), so it runs right here.
    static func runInBackground(_ done: ((Result) -> Void)? = nil) {
        let r = run()
        done?(r)
    }
}
