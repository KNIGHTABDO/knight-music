import AppIntents
import Foundation
import GRDB

// MARK: - Helper

private enum EntityDatabaseHelper {
    @MainActor
    static func database() -> LibraryDatabase? {
        if let db = AppModel.shared?.database { return db }
        let model = AppModel()
        AppModel.shared = model
        model.startIfNeeded()
        return model.database
    }
}

// MARK: - Album Entity

public struct AlbumEntity: AppEntity {
    public static var defaultQuery = AlbumQuery()
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Album"

    public var id: String
    public var name: String
    public var artist: String?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: artist.map { "\($0)" }
        )
    }

    public init(id: String, name: String, artist: String? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
    }
}

public struct AlbumQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let marks = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
            let albums = try Album.fetchAll(
                db,
                sql: "SELECT * FROM album WHERE id IN (\(marks))",
                arguments: StatementArguments(identifiers.map { $0 as (any DatabaseValueConvertible)? })
            )
            return albums.map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
        }
    }

    public func entities(matching string: String) async throws -> [AlbumEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                let albums = try LibraryQueries.albums(db, sort: .recentlyPlayed, search: "", limit: 50)
                return albums.prefix(50).map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
            }
            let searchResults = try LibraryQueries.search(db, text: q, limit: 50)
            var matches = searchResults.albums
            if matches.count < 50 {
                let candidates = try Album.fetchAll(db, sql: "SELECT * FROM album ORDER BY name COLLATE NOCASE LIMIT 200")
                let existing = Set(matches.map(\.id))
                let extra = candidates.filter { candidate in
                    !existing.contains(candidate.id) &&
                    (candidate.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                     (candidate.artist?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil))
                }
                matches.append(contentsOf: extra.prefix(50 - matches.count))
            }
            return matches.prefix(50).map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
        }
    }

    public func suggestedEntities() async throws -> [AlbumEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            var albums = try LibraryQueries.albums(db, sort: .recentlyPlayed, search: "", limit: 50)
            if albums.count < 50 {
                let recent = try LibraryQueries.albums(db, sort: .recentlyAdded, search: "", limit: 50 - albums.count)
                let existing = Set(albums.map(\.id))
                albums.append(contentsOf: recent.filter { !existing.contains($0.id) })
            }
            return albums.prefix(50).map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
        }
    }
}

// MARK: - Artist Entity

public struct ArtistEntity: AppEntity {
    public static var defaultQuery = ArtistQuery()
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"

    public var id: String
    public var name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ArtistQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let marks = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
            let artists = try Artist.fetchAll(
                db,
                sql: "SELECT * FROM artist WHERE id IN (\(marks))",
                arguments: StatementArguments(identifiers.map { $0 as (any DatabaseValueConvertible)? })
            )
            return artists.map { ArtistEntity(id: $0.id, name: $0.name) }
        }
    }

    public func entities(matching string: String) async throws -> [ArtistEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                let artists = try LibraryQueries.favoriteArtists(db)
                return artists.prefix(50).map { ArtistEntity(id: $0.id, name: $0.name) }
            }
            let searchResults = try LibraryQueries.search(db, text: q, limit: 50)
            var matches = searchResults.artists
            if matches.count < 50 {
                let candidates = try Artist.fetchAll(db, sql: "SELECT * FROM artist ORDER BY name COLLATE NOCASE LIMIT 200")
                let existing = Set(matches.map(\.id))
                let extra = candidates.filter { candidate in
                    !existing.contains(candidate.id) &&
                    candidate.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
                matches.append(contentsOf: extra.prefix(50 - matches.count))
            }
            return matches.prefix(50).map { ArtistEntity(id: $0.id, name: $0.name) }
        }
    }

    public func suggestedEntities() async throws -> [ArtistEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            var artists = try LibraryQueries.favoriteArtists(db)
            if artists.count < 50 {
                let all = try LibraryQueries.artists(db, search: "")
                let existing = Set(artists.map(\.id))
                artists.append(contentsOf: all.filter { !existing.contains($0.id) })
            }
            return artists.prefix(50).map { ArtistEntity(id: $0.id, name: $0.name) }
        }
    }
}

// MARK: - Playlist Entity

public struct PlaylistEntity: AppEntity {
    public static var defaultQuery = PlaylistQuery()
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"

    public var id: String
    public var name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct PlaylistQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let marks = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
            let playlists = try Playlist.fetchAll(
                db,
                sql: "SELECT * FROM playlist WHERE id IN (\(marks))",
                arguments: StatementArguments(identifiers.map { $0 as (any DatabaseValueConvertible)? })
            )
            return playlists.map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }

    public func entities(matching string: String) async throws -> [PlaylistEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let all = try LibraryQueries.playlists(db)
            let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = q.isEmpty ? all : all.filter {
                $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return filtered.prefix(50).map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }

    public func suggestedEntities() async throws -> [PlaylistEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let all = try LibraryQueries.playlists(db)
            return all.prefix(50).map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }
}

// MARK: - Song Entity

public struct SongEntity: AppEntity {
    public static var defaultQuery = SongQuery()
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Song"

    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: artist.map { "\($0)" }
        )
    }

    public init(id: String, title: String, artist: String? = nil, album: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
    }
}

public struct SongQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [SongEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let songs = try LibraryQueries.songs(db, ids: identifiers)
            return songs.map { SongEntity(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        }
    }

    public func entities(matching string: String) async throws -> [SongEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                var songs = try LibraryQueries.favoriteSongs(db)
                if songs.count < 50 {
                    let recent = try LibraryQueries.recentlyAddedSongs(db, limit: 50 - songs.count)
                    let existing = Set(songs.map(\.id))
                    songs.append(contentsOf: recent.filter { !existing.contains($0.id) })
                }
                return songs.prefix(50).map { SongEntity(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
            }
            let searchResults = try LibraryQueries.search(db, text: q, limit: 50)
            var matches = searchResults.songs
            if matches.count < 50 {
                let candidates = try Song.fetchAll(db, sql: "SELECT * FROM song ORDER BY title COLLATE NOCASE LIMIT 200")
                let existing = Set(matches.map(\.id))
                let extra = candidates.filter { candidate in
                    !existing.contains(candidate.id) &&
                    (candidate.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                     (candidate.artist?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil))
                }
                matches.append(contentsOf: extra.prefix(50 - matches.count))
            }
            return matches.prefix(50).map { SongEntity(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        }
    }

    public func suggestedEntities() async throws -> [SongEntity] {
        guard let database = await EntityDatabaseHelper.database() else { return [] }
        return try await database.pool.read { db in
            var songs = try LibraryQueries.favoriteSongs(db)
            if songs.count < 50 {
                let recent = try LibraryQueries.recentlyAddedSongs(db, limit: 50 - songs.count)
                let existing = Set(songs.map(\.id))
                songs.append(contentsOf: recent.filter { !existing.contains($0.id) })
            }
            return songs.prefix(50).map { SongEntity(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        }
    }
}
