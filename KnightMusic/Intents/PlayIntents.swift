import AppIntents
import Foundation
import GRDB

// MARK: - Errors & Setup

public enum IntentError: LocalizedError {
    case notSignedIn
    case message(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Please open Knight Music and sign in."
        case .message(let msg):
            return msg
        case .notFound(let item):
            return "Could not find \(item) in your library."
        }
    }
}

@MainActor
func prepareAppForPlayback() async throws -> (AppModel, LibraryDatabase) {
    // KnightMusicApp.init creates the one AppModel before any intent runs in the app process.
    guard let app = AppModel.shared else { throw IntentError.notSignedIn }
    app.startIfNeeded()

    if app.session != .ready || app.database == nil {
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if app.session == .ready && app.database != nil {
                break
            }
            if case .loggedOut = app.session, app.accounts.active == nil {
                throw IntentError.notSignedIn
            }
        }
    }

    guard app.session == .ready, let db = app.database else {
        if app.session == .loggedOut || app.accounts.active == nil {
            throw IntentError.notSignedIn
        } else if case .failed(let message) = app.session {
            throw IntentError.message("Could not connect to Knight Music: \(message)")
        } else {
            throw IntentError.message("Knight Music is not ready. Please open the app and try again.")
        }
    }

    return (app, db)
}

// MARK: - Play Album Intent

public struct PlayAlbumIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Album"
    public static var description = IntentDescription("Plays an album from your library in Knight Music.")
    public static var openAppWhenRun: Bool = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Album")
    public var album: AlbumEntity

    public init() {}

    public init(album: AlbumEntity) {
        self.album = album
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let (app, db) = try await prepareAppForPlayback()
        let content = try await db.pool.read { db in
            try LibraryQueries.album(db, id: album.id)
        }
        guard !content.songs.isEmpty else {
            throw IntentError.message("Album \(album.name) has no songs.")
        }
        app.player.play(content.songs, startAt: 0, shuffle: false)

        let albumTitle = content.album?.name ?? album.name
        let artistName = content.album?.artist ?? album.artist
        let dialog: IntentDialog
        if let artistName, !artistName.isEmpty {
            dialog = "Playing \(albumTitle) by \(artistName)"
        } else {
            dialog = "Playing \(albumTitle)"
        }
        return .result(dialog: dialog)
    }
}

// MARK: - Play Artist Intent

public struct PlayArtistIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Artist"
    public static var description = IntentDescription("Plays songs by an artist, shuffled, in Knight Music.")
    public static var openAppWhenRun: Bool = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Artist")
    public var artist: ArtistEntity

    public init() {}

    public init(artist: ArtistEntity) {
        self.artist = artist
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let (app, db) = try await prepareAppForPlayback()
        let songs = try await db.pool.read { db in
            try LibraryQueries.songs(db, artistId: artist.id)
        }
        guard !songs.isEmpty else {
            throw IntentError.message("No songs found for \(artist.name).")
        }
        app.player.play(songs, startAt: 0, shuffle: true)
        return .result(dialog: "Playing songs by \(artist.name)")
    }
}

// MARK: - Play Playlist Intent

public struct PlayPlaylistIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Playlist"
    public static var description = IntentDescription("Plays a playlist from your library in Knight Music.")
    public static var openAppWhenRun: Bool = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Playlist")
    public var playlist: PlaylistEntity

    public init() {}

    public init(playlist: PlaylistEntity) {
        self.playlist = playlist
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let (app, db) = try await prepareAppForPlayback()
        let songs = try await db.pool.read { db in
            try LibraryQueries.playlistSongs(db, id: playlist.id)
        }
        guard !songs.isEmpty else {
            throw IntentError.message("Playlist \(playlist.name) has no songs.")
        }
        app.player.play(songs, startAt: 0, shuffle: false)
        return .result(dialog: "Playing playlist \(playlist.name)")
    }
}

// MARK: - Play Song Intent

public struct PlaySongIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Song"
    public static var description = IntentDescription("Plays a song from your library in Knight Music.")
    public static var openAppWhenRun: Bool = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Song")
    public var song: SongEntity

    public init() {}

    public init(song: SongEntity) {
        self.song = song
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let (app, db) = try await prepareAppForPlayback()
        let songs = try await db.pool.read { db in
            try LibraryQueries.songs(db, ids: [song.id])
        }
        guard let songRecord = songs.first else {
            throw IntentError.notFound(song.title)
        }
        app.player.play([songRecord], startAt: 0, shuffle: false)

        let artistName = songRecord.artist ?? song.artist
        let dialog: IntentDialog
        if let artistName, !artistName.isEmpty {
            dialog = "Playing \(songRecord.title) by \(artistName)"
        } else {
            dialog = "Playing \(songRecord.title)"
        }
        return .result(dialog: dialog)
    }
}

// MARK: - Resume Intent

public struct ResumeIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Resume"
    public static var description = IntentDescription("Resumes playback or shuffles your library in Knight Music.")
    public static var openAppWhenRun: Bool = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let (app, db) = try await prepareAppForPlayback()
        if app.player.order.isEmpty {
            let songs = try await db.pool.read { db in
                try Song.fetchAll(db, sql: "SELECT * FROM song ORDER BY RANDOM() LIMIT 200")
            }
            guard !songs.isEmpty else {
                throw IntentError.message("No songs found in library.")
            }
            app.player.play(songs, startAt: 0, shuffle: false)
            return .result(dialog: "Shuffling your library")
        } else {
            app.player.resume()
            let dialog: IntentDialog
            if let current = app.player.currentSong {
                dialog = "Resuming \(current.title)"
            } else {
                dialog = "Resuming playback"
            }
            return .result(dialog: dialog)
        }
    }
}

// MARK: - Pause Intent

public struct PauseIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Pause"
    public static var description = IntentDescription("Pauses playback in Knight Music.")
    public static var openAppWhenRun: Bool = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app = AppModel.shared else {
            return .result(dialog: "Paused")
        }
        app.startIfNeeded()
        app.player.pause()
        return .result(dialog: "Paused")
    }
}

// MARK: - Play Downloads Intent

public struct PlayDownloadsIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Downloads"
    public static var description = IntentDescription("Plays downloaded songs, shuffled, in Knight Music.")
    public static var openAppWhenRun: Bool = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let (app, db) = try await prepareAppForPlayback()
        let songs = try await db.pool.read { db in
            try LibraryQueries.downloadedSongs(db)
        }
        guard !songs.isEmpty else {
            throw IntentError.message("No downloaded songs available in Knight Music.")
        }
        app.player.play(songs, startAt: 0, shuffle: true)
        return .result(dialog: "Playing downloaded songs")
    }
}

// MARK: - Authentication Policy Extensions for Widget Intents

extension ShuffleLibraryIntent {
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
}

extension PlayFavoritesIntent {
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
}

extension NextTrackIntent {
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
}

extension PreviousTrackIntent {
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
}
