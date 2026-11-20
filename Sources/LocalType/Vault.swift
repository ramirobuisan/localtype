import CryptoKit
import Foundation
import Security

/// Encryption for data LocalType keeps on disk (the typing history). AES-GCM with a 256-bit key that is created on
/// first use and stored in the login Keychain, so the file on disk is unreadable without this Mac's Keychain.
enum Vault {
    private static let service = "io.github.ramirobuisan.localtype"
    private static let account = "history-key"

    private static var cached: SymmetricKey?

    static func key() -> SymmetricKey? {
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 {
            cached = SymmetricKey(data: data)
            return cached
        }
        let new = SymmetricKey(size: .bits256)
        let data = new.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: data,
                                  kSecAttrLabel as String: "LocalType typing history key",
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cached = new
        return new
    }

    // MARK: Sync key (derived from the user's sync passphrase; the passphrase itself is never stored)

    private static let syncAccount = "sync-key"

    static var syncKey: SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: syncAccount, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func setSyncKey(_ key: SymmetricKey?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: syncAccount]
        SecItemDelete(base as CFDictionary)
        guard let key else { return }
        var add = base
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrLabel as String] = "LocalType sync key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func seal(_ data: Data, with key: SymmetricKey) -> Data? { try? AES.GCM.seal(data, using: key).combined }
    static func open(_ data: Data, with key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func seal(_ data: Data) -> Data? {
        guard let key = key() else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    static func open(_ data: Data) -> Data? {
        guard let key = key(), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
