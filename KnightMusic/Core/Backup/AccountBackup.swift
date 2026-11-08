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

    static func encode(_ envelope: BackupEnvelope) throws -> String {
        let json = try JSONEncoder().encode(envelope)
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        return commentPrefix + compressed.base64EncodedString()
    }

    static func decode(_ comment: String?) -> BackupEnvelope? {
        guard let comment, comment.hasPrefix(commentPrefix),
              let compressed = Data(base64Encoded: String(comment.dropFirst(commentPrefix.count))) else { return nil }
        do {
            let json = try (compressed as NSData).decompressed(using: .zlib) as Data
            let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: json)
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
