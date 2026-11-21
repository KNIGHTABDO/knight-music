import Foundation
import UIKit

/// Reads the device's restorable state into a `BackupContent` and writes one back.
@MainActor
enum BackupSnapshot {
    /// Keychain items (besides server passwords) that follow the account.
    static let secretAccounts = ["hermes_api_key", "discord_user_token"]

    /// Keys that describe this device, this install, or transient work — never synced.
    private static let excludedPrefixes = [
        "Apple", "NS", "UI", "com.apple", "WebKit", "AK", "PK", "IN", "_",
        "KM",                       // screenshot / demo launch arguments
        "backup.",                  // the backup's own bookkeeping
        "spotlight.signature.",
        "resolvedAddress.",
        "knight_pending_arrival_watches",
        "km.lastOfferedLinkChangeCount",
    ]

    static var deviceKind: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
    }

    static func isSynced(key: String) -> Bool {
        !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: - Capture

    static func capture(account: ServerAccount?, downloadedSongIds: Set<String>, otherDevicesDownloads: [String: [String]]) -> BackupContent {
        var content = BackupContent()
        if let bundleId = Bundle.main.bundleIdentifier,
           let domain = UserDefaults.standard.persistentDomain(forName: bundleId) {
            for (key, value) in domain where isSynced(key: key) {
                if let converted = DefaultsValue(plist: value) { content.defaults[key] = converted }
            }
        }
        for account in secretAccounts {
            if let secret = Keychain.get(account: account), !secret.isEmpty { content.secrets[account] = secret }
        }
        content.serverAddresses = account?.addresses.map(\.absoluteString) ?? []
        content.conversations = readConversations()
        content.downloads = otherDevicesDownloads
        content.downloads[deviceKind] = downloadedSongIds.isEmpty ? nil : downloadedSongIds.sorted()
        return content
    }

    // MARK: - Apply

    /// Writes `content` into UserDefaults, the Keychain and the Knight chat folder. Callers reload live stores afterwards.
    static func apply(_ content: BackupContent) {
        let defaults = UserDefaults.standard
        if let bundleId = Bundle.main.bundleIdentifier,
           let domain = defaults.persistentDomain(forName: bundleId) {
            for key in domain.keys where isSynced(key: key) && content.defaults[key] == nil {
                defaults.removeObject(forKey: key)
            }
        }
        for (key, value) in content.defaults where isSynced(key: key) {
            defaults.set(value.plistValue, forKey: key)
        }
        for account in secretAccounts {
            if let secret = content.secrets[account], !secret.isEmpty {
                do { try Keychain.set(secret, account: account) } catch {
                    Log.app.error("Restoring \(account) to the Keychain failed: \(error)")
                }
            } else if content.undecryptedSecrets[account] == nil {
                // Only when the backup really has no such secret: one we couldn't decrypt keeps the local copy.
                Keychain.delete(account: account)
            }
        }
        writeConversations(content.conversations)
    }

    // MARK: - Knight chats

    private static var conversationsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Knight", isDirectory: true)
    }

    private static func readConversations() -> [String: Data] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: conversationsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file) { result[file.lastPathComponent] = data }
        }
        return result
    }

    private static func writeConversations(_ conversations: [String: Data]) {
        let fm = FileManager.default
        let directory = conversationsDirectory
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for file in existing where file.pathExtension == "json" && conversations[file.lastPathComponent] == nil {
                try fm.removeItem(at: file)
            }
            for (name, data) in conversations {
                // File names come from the server: keep them to plain "<id>.json" inside the folder.
                let safeName = (name as NSString).lastPathComponent
                guard safeName.hasSuffix(".json"), !safeName.hasPrefix(".") else { continue }
                try data.write(to: directory.appendingPathComponent(safeName), options: [.atomic])
            }
        } catch {
            Log.app.error("Restoring Knight chats failed: \(error)")
        }
    }
}
