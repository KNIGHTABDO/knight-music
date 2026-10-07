import Foundation
import Security

/// Minimal generic-password wrapper. Items are readable after first unlock so background sync and
/// playback keep working while the device is locked.
///
/// Builds without a signing identity (simulator CI, `CODE_SIGNING_ALLOWED=NO`) have no keychain entitlement
/// (errSecMissingEntitlement, -34018). In that case secrets fall back to a file in Application Support that
/// is protected until first unlock. Signed installs (SideStore) always use the Keychain.
enum Keychain {
    static let service = "com.knightabdo.knightmusic"

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            if case .status(let s) = self { return "Keychain error \(s)" }
            return nil
        }
    }

    static func set(_ value: String, account: String) throws {
        let base = baseQuery(account)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess {
            fallbackRemove(account)
            return
        }
        if status == errSecMissingEntitlement {
            Log.app.warning("Keychain unavailable (unsigned build); using protected file fallback")
            try fallbackStore(value, account: account)
            return
        }
        Log.app.error("Keychain add failed: \(status)")
        throw KeychainError.status(status)
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return fallbackLoad()[account]
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        fallbackRemove(account)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - File fallback

    private static var fallbackURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("credentials.json")
    }

    private static func fallbackLoad() -> [String: String] {
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fallbackURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            Log.app.error("Failed to read credentials fallback: \(error)")
            return [:]
        }
    }

    private static func fallbackSave(_ dict: [String: String]) throws {
        let url = fallbackURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if dict.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder().encode(dict)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func fallbackStore(_ value: String, account: String) throws {
        var dict = fallbackLoad()
        dict[account] = value
        try fallbackSave(dict)
    }

    private static func fallbackRemove(_ account: String) {
        var dict = fallbackLoad()
        guard dict.removeValue(forKey: account) != nil else { return }
        do {
            try fallbackSave(dict)
        } catch {
            Log.app.error("Failed to remove credential from fallback: \(error)")
        }
    }
}
