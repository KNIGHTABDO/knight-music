import AppIntents
import Foundation
import GRDB

public struct PlayAlbumIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Album"
    public static var description = IntentDescription("Plays an album from your library in Knight Music.")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Album")
    public var album: AlbumEntity

    public init() {}

    public init(album: AlbumEntity) {
        self.album = album
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let app = AppModel.shared, let db = app.database else {
            return .result()
        }
        let content = try await db.pool.read { db in
            try LibraryQueries.album(db, id: album.id)
        }
        guard !content.songs.isEmpty else { return .result() }
        app.player.play(content.songs, startAt: 0, shuffle: false)
        return .result()
    }
}

public struct PlayArtistIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Artist"
    public static var description = IntentDescription("Plays songs by an artist, shuffled, in Knight Music.")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Artist")
    public var artist: ArtistEntity

    public init() {}

    public init(artist: ArtistEntity) {
        self.artist = artist
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let app = AppModel.shared, let db = app.database else {
            return .result()
        }
        let songs = try await db.pool.read { db in
            try LibraryQueries.songs(db, artistId: artist.id)
        }
        guard !songs.isEmpty else { return .result() }
        app.player.play(songs, startAt: 0, shuffle: true)
        return .result()
    }
}

public struct PlayPlaylistIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Playlist"
    public static var description = IntentDescription("Plays a playlist from your library in Knight Music.")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Playlist")
    public var playlist: PlaylistEntity

    public init() {}

    public init(playlist: PlaylistEntity) {
        self.playlist = playlist
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let app = AppModel.shared, let db = app.database else {
            return .result()
        }
        let songs = try await db.pool.read { db in
            try LibraryQueries.playlistSongs(db, id: playlist.id)
        }
        guard !songs.isEmpty else { return .result() }
        app.player.play(songs, startAt: 0, shuffle: false)
        return .result()
    }
}
