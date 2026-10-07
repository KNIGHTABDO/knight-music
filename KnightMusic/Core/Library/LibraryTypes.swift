import Foundation
import GRDB

/// Server-ordered shelves on the Home screen.
enum HomeKind: String, CaseIterable, Sendable {
    case newest, recent, frequent, random, starred

    var albumListType: AlbumListType {
        switch self {
        case .newest: return .newest
        case .recent: return .recent
        case .frequent: return .frequent
        case .random: return .random
        case .starred: return .starred
        }
    }

    var size: Int { self == .starred ? 60 : 40 }
}

enum AlbumSort: String, CaseIterable, Sendable {
    case name, artist, year, recentlyAdded, mostPlayed, recentlyPlayed
}

enum SongSort: String, CaseIterable, Sendable {
    case title, artist, album, year, recentlyAdded, mostPlayed, recentlyPlayed
}

struct SearchResults: Sendable, Equatable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []
    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
    static let empty = SearchResults()
}

/// An album with its tracks ordered by disc and track number.
struct AlbumContent: Sendable, Equatable {
    var album: Album?
    var songs: [Song] = []
}

struct LibraryCounts: Sendable, Equatable {
    var artists = 0
    var albums = 0
    var songs = 0
    var playlists = 0
}

enum LibraryError: LocalizedError {
    case notSignedIn
    case offline
    case notFound

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You are not signed in to a server."
        case .offline: return "You are offline. Go online to make this change."
        case .notFound: return "That item is no longer in your library."
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - Shared writes (used by SyncEngine and LibraryRepository)

extension LibraryDatabase {
    func storePlaylist(_ playlist: Playlist, songs: [Song]) async throws {
        try await pool.write { db in
            try playlist.upsert(db)
            for song in songs { try song.upsert(db) }
            try db.execute(sql: "DELETE FROM playlistEntry WHERE playlistId = ?", arguments: [playlist.id])
            for (index, song) in songs.enumerated() {
                try PlaylistEntry(playlistId: playlist.id, position: index, songId: song.id).insert(db)
            }
        }
    }

    func storeHomeList(_ kind: HomeKind, albums: [Album]) async throws {
        try await pool.write { db in
            for album in albums { try album.upsert(db) }
            try db.execute(sql: "DELETE FROM homeList WHERE kind = ?", arguments: [kind.rawValue])
            for (index, album) in albums.enumerated() {
                try db.execute(
                    sql: "INSERT INTO homeList(kind, position, albumId) VALUES (?, ?, ?)",
                    arguments: [kind.rawValue, index, album.id]
                )
            }
        }
    }
}
