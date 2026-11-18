import CryptoKit
import Foundation

/// Everything Knight Music keeps on the device that can't be re-synced from the library:
/// preferences, looks, EQ, AI / Discord credentials, Knight chats, extra server addresses, and which songs
/// each device had downloaded. Stored on the Navidrome account itself (see `AccountBackupService`).
struct BackupContent: Codable, Equatable, Sendable {
    var defaults: [String: DefaultsValue] = [:]
    /// Keychain account → secret.
    var secrets: [String: String] = [:]
    var serverAddresses: [String] = []
    /// Knight chat files by file name.
    var conversations: [String: Data] = [:]
    /// Device kind ("phone" / "pad") → downloaded song ids.
    var downloads: [String: [String]] = [:]

    /// Stable fingerprint, used to tell whether anything changed since the last sync.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct BackupEnvelope: Codable, Sendable {
    static let currentFormat = 1

    var format: Int = Self.currentFormat
    var updatedAt: Date
    var deviceId: String
    var deviceName: String
    var appVersion: String
    var content: BackupContent
}

/// The backup travels in the comment of a private, empty playlist owned by the user.
enum BackupCodec {
    static let playlistName = "Knight Music Backup"
    static let commentPrefix = "KMBACKUP1:"

    static func isBackup(_ playlist: Playlist) -> Bool {
        playlist.comment?.hasPrefix(commentPrefix) == true || playlist.name == playlistName
    }

    // MARK: Secret protection

    /// Secrets are AES-GCM sealed with a key from the account password + username, so a restore on another
    /// device signed into the same server can open them, while the server (and anyone reading the playlist) cannot.
    private static let secretPrefix = "enc1:"
    private static let hkdfSalt = Data("KnightMusic.backup.secrets.v1".utf8)

    static func secretKey(password: String, username: String) -> SymmetricKey? {
        guard !password.isEmpty else { return nil }
        let ikm = SymmetricKey(data: Data((username + "\u{0}" + password).utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: hkdfSalt, info: Data("secrets".utf8), outputByteCount: 32)
    }

    private static func sealSecrets(_ secrets: [String: String], key: SymmetricKey?) -> [String: String] {
        // No password to derive a key from: upload no secrets rather than clear text.
        guard let key else { return [:] }
        var out: [String: String] = [:]
        for (name, value) in secrets {
            do {
                let box = try AES.GCM.seal(Data(value.utf8), using: key)
                if let combined = box.combined { out[name] = secretPrefix + combined.base64EncodedString() }
            } catch {
                Log.app.error("Backup: sealing \(name) failed: \(error)")
            }
        }
        return out
    }

    private static func openSecrets(_ secrets: [String: String], key: SymmetricKey?) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in secrets {
            guard value.hasPrefix(secretPrefix) else { out[name] = value; continue } // older clear-text backup
            guard let key,
                  let data = Data(base64Encoded: String(value.dropFirst(secretPrefix.count))),
                  let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: key),
                  let text = String(data: plain, encoding: .utf8) else {
                Log.app.error("Backup: could not decrypt \(name) (different password?); skipping it")
                continue
            }
            out[name] = text
        }
        return out
    }

    static func encode(_ envelope: BackupEnvelope, key: SymmetricKey?) throws -> String {
        var envelope = envelope
        envelope.content.secrets = sealSecrets(envelope.content.secrets, key: key)
        let json = try JSONEncoder().encode(envelope)
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        return commentPrefix + compressed.base64EncodedString()
    }

    static func decode(_ comment: String?, key: SymmetricKey?) -> BackupEnvelope? {
        guard let comment, comment.hasPrefix(commentPrefix),
              let compressed = Data(base64Encoded: String(comment.dropFirst(commentPrefix.count))) else { return nil }
        do {
            let json = try (compressed as NSData).decompressed(using: .zlib) as Data
            var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: json)
            envelope.content.secrets = openSecrets(envelope.content.secrets, key: key)
            guard envelope.format <= BackupEnvelope.currentFormat else {
                Log.app.error("Backup was written by a newer Knight Music (format \(envelope.format)); update the app to use it")
                return nil
            }
            return envelope
        } catch {
            Log.app.error("Backup on server is unreadable: \(error)")
            return nil
        }
    }
}
