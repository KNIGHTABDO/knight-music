import Foundation
import GRDB
import UIKit
import os

// Small injected interfaces so Playback/Downloads never depend on the API / Artwork / Settings modules
// directly. The integrator (AppModel) conforms the real types and fills `PlaybackServices`.

enum PlaybackLog {
    static let logger = Logger(subsystem: "com.knightabdo.knightmusic", category: "playback")
}

enum PlaybackNetworkStatus: Sendable {
    case offline, wifi, cellular
}

enum ReplayGainMode: String, Codable, CaseIterable, Sendable {
    case off, track, album
}

/// Snapshot of every user setting playback/downloads care about. 0 bitrate means "original quality".
struct PlaybackSettings: Equatable, Sendable {
    var wifiMaxBitRate: Int = 0
    var cellularMaxBitRate: Int = 0
    /// Target container when transcoding for streaming (e.g. "mp3", "opus"). Ignored for original quality.
    var transcodeFormat: String? = nil
    /// 0 = download the original file via `downloadURL`, otherwise transcoded via `streamURL`.
    var downloadMaxBitRate: Int = 0
    var downloadFormat: String? = nil
    var downloadOnCellular: Bool = true
    var gapless: Bool = true
    var replayGain: ReplayGainMode = .off
    var scrobblingEnabled: Bool = true
    var offlineMode: Bool = false
    var streamCacheEnabled: Bool = true
    var streamCacheLimitMB: Int = 2048
    var serverQueueSyncEnabled: Bool = true
}

protocol PlaybackURLProvider: Sendable {
    func streamURL(songId: String, maxBitRate: Int?, format: String?, timeOffset: Int?) -> URL
    func downloadURL(songId: String) -> URL
}

struct ServerPlayQueue {
    var songs: [Song]
    var currentSongId: String?
    var positionMs: Int
    var changed: Date?
    var changedBy: String?
}

protocol PlaybackServerActions: Sendable {
    func scrobble(songId: String, time: Date, submission: Bool) async throws
    func savePlayQueue(songIds: [String], currentSongId: String?, positionMs: Int) async throws
    func getPlayQueue() async throws -> ServerPlayQueue?
    /// Stars/unstars on the server. The conformer should also update the local mirror.
    func setStarred(songId: String, starred: Bool) async throws
}

protocol ArtworkProviding {
    func image(coverArt: String?, size: Int) async -> UIImage?
    /// MPNowPlayingInfo entries for animated lock-screen artwork (empty when none).
    func nowPlayingEntries(for song: Song) async -> [String: Any]
}

/// Shared, mutable wiring. One instance is handed to PlayerEngine, DownloadManager and StorageManager.
/// Replace `urls`/`server` whenever the active client/address changes.
final class PlaybackServices: @unchecked Sendable {
    var urls: PlaybackURLProvider?
    var server: PlaybackServerActions?
    var artwork: ArtworkProviding?
    var settingsProvider: () -> PlaybackSettings = { PlaybackSettings() }
    var networkProvider: () -> PlaybackNetworkStatus = { .wifi }

    var settings: PlaybackSettings { settingsProvider() }
    var network: PlaybackNetworkStatus { networkProvider() }
    var isOffline: Bool { settings.offlineMode || network == .offline }
}

/// Quality requested from the server for a stream (or transcoded download).
struct StreamQuality: Equatable, Sendable {
    var maxBitRate: Int?
    var format: String?

    static let original = StreamQuality(maxBitRate: nil, format: nil)

    /// Persisted form: "raw" or "mp3@192".
    var key: String {
        if let maxBitRate { return "\(format ?? "mp3")@\(maxBitRate)" }
        return "raw"
    }

    init(maxBitRate: Int?, format: String?) {
        self.maxBitRate = maxBitRate
        self.format = format
    }

    init(key: String?) {
        if let key, key != "raw", let at = key.firstIndex(of: "@"),
           let rate = Int(key[key.index(after: at)...]) {
            maxBitRate = rate
            format = String(key[..<at])
        } else {
            maxBitRate = nil
            format = nil
        }
    }
}

enum AudioDescription {
    static func make(kind: AudioSource, song: Song, quality: StreamQuality?,
                     fileExtension: String? = nil, fileBytes: Int? = nil) -> String {
        if kind == .radio { return "Live Radio" }
        let prefix: String
        switch kind {
        case .downloaded: prefix = "Downloaded"
        case .cached: prefix = "Cached"
        default: prefix = "Streaming"
        }
        var format: String?
        var bitrate: Int?
        if kind == .downloaded {
            format = fileExtension ?? song.suffix
            if fileExtension == nil || fileExtension?.lowercased() == song.suffix?.lowercased() {
                bitrate = song.bitRate
            } else if let fileBytes, song.durationSeconds > 0 {
                bitrate = Int(Double(fileBytes) * 8 / 1000 / song.durationSeconds)
            }
        } else if let max = quality?.maxBitRate, (song.bitRate ?? Int.max) > max {
            format = quality?.format ?? "mp3"
            bitrate = max
        } else {
            format = song.suffix
            bitrate = song.bitRate
        }
        var parts = [prefix]
        if let format, !format.isEmpty { parts.append(format.uppercased()) }
        if let bitrate, bitrate > 0 { parts.append("\(bitrate) kbps") }
        return parts.joined(separator: " \u{2022} ")
    }
}

func safeFileComponent(_ s: String) -> String {
    s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
}

func excludeFromBackup(_ url: URL) {
    var u = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? u.setResourceValues(values)
}

// MARK: - GRDB records (tables are created by LibraryDatabase migrations)

struct DownloadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "download"
    var songId: String
    var state: String
    var progress: Double
    var bytes: Int
    var relativePath: String?
    var addedAt: Date
    var errorMessage: String?
}

struct CachedSongRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cachedSong"
    var songId: String
    var relativePath: String
    var bytes: Int
    var lastAccess: Date
    var quality: String?
}

struct PendingScrobbleRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pendingScrobble"
    var id: Int64?
    var songId: String
    var time: Date
    var submission: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
