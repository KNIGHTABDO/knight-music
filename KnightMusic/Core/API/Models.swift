import Foundation
import GRDB

// Domain models. They decode straight from OpenSubsonic JSON (Navidrome) and are stored as-is in the
// local GRDB database (see LibraryDatabase.swift). Dates are ISO-8601 from the server.
// Keep these the single source of truth; UI and playback import them, never raw JSON.

struct Artist: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "artist"
    var id: String
    var name: String
    var coverArt: String?
    var artistImageUrl: String?
    var albumCount: Int?
    var starred: Date?
    var sortName: String?
}

struct Album: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "album"
    var id: String
    var name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var playCount: Int?
    var played: Date?
    var created: Date?
    var starred: Date?
    var year: Int?
    var genre: String?
    var userRating: Int?
    var sortName: String?
    var isCompilation: Bool?
}

struct Song: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "song"
    var id: String
    var title: String
    var album: String?
    var albumId: String?
    var artist: String?
    var artistId: String?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var coverArt: String?
    var size: Int?
    var contentType: String?
    var suffix: String?
    var duration: Int?
    var bitRate: Int?
    var samplingRate: Int?
    var path: String?
    var playCount: Int?
    var played: Date?
    var created: Date?
    var starred: Date?
    var userRating: Int?
    var bpm: Int?
    var comment: String?
    var sortName: String?
    var displayComposer: String?
    var replayGain: ReplayGain?

    var durationSeconds: TimeInterval { TimeInterval(duration ?? 0) }
}

struct ReplayGain: Codable, Hashable {
    var trackGain: Double?
    var albumGain: Double?
    var trackPeak: Double?
    var albumPeak: Double?
}

struct Playlist: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlist"
    var id: String
    var name: String
    var comment: String?
    var owner: String?
    var `public`: Bool?
    var songCount: Int?
    var duration: Int?
    var created: Date?
    var changed: Date?
    var coverArt: String?
}

/// Ordered membership of songs in a playlist (local mirror).
struct PlaylistEntry: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlistEntry"
    var playlistId: String
    var position: Int
    var songId: String
}

struct Genre: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "genre"
    var value: String
    var songCount: Int?
    var albumCount: Int?
    var id: String { value }
}

struct RadioStation: Codable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "radioStation"
    var id: String
    var name: String
    var streamUrl: String
    var homePageUrl: String?
}

/// OpenSubsonic getLyricsBySongId → structuredLyrics. `synced` lines carry `start` in ms.
struct StructuredLyrics: Codable, Hashable {
    var lang: String?
    var synced: Bool
    var displayArtist: String?
    var displayTitle: String?
    var offset: Int?
    var line: [Line]
    struct Line: Codable, Hashable {
        var start: Int?
        var value: String
    }
}

struct ScanStatus: Codable, Hashable {
    var scanning: Bool
    var count: Int?
    var folderCount: Int?
    var lastScan: Date?
}

/// Where a playable item's audio comes from right now (shown in the player: "Streaming • MP3 • 249 kbps").
enum AudioSource: String, Codable {
    case streaming, cached, downloaded, radio
}
