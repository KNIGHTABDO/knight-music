import AppIntents
import Foundation
import GRDB

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
        guard let database = await AppModel.shared?.database else { return [] }
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
        guard let database = await AppModel.shared?.database else { return [] }
        return try await database.pool.read { db in
            let albums = try LibraryQueries.albums(db, sort: .name, search: string, limit: 20)
            return albums.map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
        }
    }

    public func suggestedEntities() async throws -> [AlbumEntity] {
        guard let database = await AppModel.shared?.database else { return [] }
        return try await database.pool.read { db in
            let albums = try LibraryQueries.albums(db, sort: .recentlyPlayed, search: "", limit: 10)
            return albums.map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
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
        guard let database = await AppModel.shared?.database else { return [] }
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
        guard let database = await AppModel.shared?.database else { return [] }
        return try await database.pool.read { db in
            let artists = try LibraryQueries.artists(db, search: string)
            return artists.prefix(20).map { ArtistEntity(id: $0.id, name: $0.name) }
        }
    }

    public func suggestedEntities() async throws -> [ArtistEntity] {
        guard let database = await AppModel.shared?.database else { return [] }
        return try await database.pool.read { db in
            let artists = try LibraryQueries.favoriteArtists(db)
            return artists.prefix(10).map { ArtistEntity(id: $0.id, name: $0.name) }
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
        guard let database = await AppModel.shared?.database else { return [] }
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
        guard let database = await AppModel.shared?.database else { return [] }
        return try await database.pool.read { db in
            let all = try LibraryQueries.playlists(db)
            let filtered = string.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(string) }
            return filtered.prefix(20).map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }

    public func suggestedEntities() async throws -> [PlaylistEntity] {
        guard let database = await AppModel.shared?.database else { return [] }
        return try await database.pool.read { db in
            let all = try LibraryQueries.playlists(db)
            return all.prefix(10).map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }
}
