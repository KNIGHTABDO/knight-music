import Foundation
import GRDB

/// The only thing UI reads library data from. Every factory returns a `LiveQuery` backed by the local mirror.
/// Instances are cached per query (LRU), so calling a factory inside `body` is cheap and a re-created screen
/// shows its last value instantly. Mutations go to the server first (optimistic where safe), then the mirror.
@MainActor @Observable
final class LibraryRepository {
    enum StarKind { case song, album, artist }

    /// Last mutation failure, for a global toast/banner. Cleared by the UI after display.
    var lastError: String?

    @ObservationIgnored private(set) var database: LibraryDatabase?
    @ObservationIgnored private var client: SubsonicClient?
    @ObservationIgnored private var syncEngine: SyncEngine?
    @ObservationIgnored var isOfflineProvider: () -> Bool = { false }
    @ObservationIgnored var onSongStarChanged: ((String, Bool) -> Void)?

    @ObservationIgnored private var cache: [String: AnyObject] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var searchCache: [String: AnyObject] = [:]
    @ObservationIgnored private var searchCacheOrder: [String] = []
    @ObservationIgnored private var requestedTopSongs = Set<String>()
    private static let cacheLimit = 48
    private static let searchCacheLimit = 2

    init() {}

    /// Called by AppModel whenever the session changes.
    func configure(database: LibraryDatabase?, client: SubsonicClient?, syncEngine: SyncEngine?) {
        if self.database !== database {
            cache.removeAll()
            cacheOrder.removeAll()
            searchCache.removeAll()
            searchCacheOrder.removeAll()
            requestedTopSongs.removeAll()
        }
        self.database = database
        self.client = client
        self.syncEngine = syncEngine
    }

    func dropCaches() {
        cache.removeAll()
        cacheOrder.removeAll()
        searchCache.removeAll()
        searchCacheOrder.removeAll()
    }

    // MARK: - Query cache

    private func query<V: Sendable & Equatable>(
        _ key: String,
        initial: V,
        isSearch: Bool = false,
        _ fetch: @escaping @Sendable (Database) throws -> V
    ) -> LiveQuery<V> {
        if isSearch {
            if let hit = searchCache[key] as? LiveQuery<V> {
                if let index = searchCacheOrder.firstIndex(of: key), index != searchCacheOrder.count - 1 {
                    searchCacheOrder.remove(at: index)
                    searchCacheOrder.append(key)
                }
                return hit
            }
            let made = LiveQuery(initial: initial, database: database, fetch: fetch)
            searchCache[key] = made
            searchCacheOrder.append(key)
            if searchCacheOrder.count > Self.searchCacheLimit {
                let evicted = searchCacheOrder.removeFirst()
                searchCache[evicted] = nil
            }
            return made
        } else {
            if let hit = cache[key] as? LiveQuery<V> {
                if let index = cacheOrder.firstIndex(of: key), index != cacheOrder.count - 1 {
                    cacheOrder.remove(at: index)
                    cacheOrder.append(key)
                }
                return hit
            }
            let made = LiveQuery(initial: initial, database: database, fetch: fetch)
            cache[key] = made
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                let evicted = cacheOrder.removeFirst()
                cache[evicted] = nil
            }
            return made
        }
    }

    // MARK: - Artists

    func artists(search: String = "") -> LiveQuery<[Artist]> {
        query("artists:\(search)", initial: [Artist]()) { db in try LibraryQueries.artists(db, search: search) }
    }

    func favoriteArtists() -> LiveQuery<[Artist]> {
        query("favoriteArtists", initial: [Artist]()) { db in try LibraryQueries.favoriteArtists(db) }
    }

    func artist(id: String) -> LiveQuery<Artist?> {
        query("artist:\(id)", initial: Artist?.none) { db in try LibraryQueries.artist(db, id: id) }
    }

    // MARK: - Albums

    func albums(sort: AlbumSort = .name, search: String = "", limit: Int? = nil) -> LiveQuery<[Album]> {
        let isSearch = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return query("albums:\(sort.rawValue):\(search):\(limit ?? 0)", initial: [Album](), isSearch: isSearch) { db in
            try LibraryQueries.albums(db, sort: sort, search: search, limit: limit)
        }
    }

    func favoriteAlbums() -> LiveQuery<[Album]> {
        query("favoriteAlbums", initial: [Album]()) { db in try LibraryQueries.favoriteAlbums(db) }
    }

    func albums(artistId: String) -> LiveQuery<[Album]> {
        query("albumsByArtist:\(artistId)", initial: [Album]()) { db in try LibraryQueries.albums(db, artistId: artistId) }
    }

    func albums(genre: String) -> LiveQuery<[Album]> {
        query("albumsByGenre:\(genre)", initial: [Album]()) { db in try LibraryQueries.albums(db, genre: genre) }
    }

    /// Album plus its songs ordered by disc and track.
    func album(id: String) -> LiveQuery<AlbumContent> {
        query("album:\(id)", initial: AlbumContent()) { db in try LibraryQueries.album(db, id: id) }
    }

    func homeList(_ kind: HomeKind) -> LiveQuery<[Album]> {
        query("home:\(kind.rawValue)", initial: [Album]()) { db in try LibraryQueries.homeList(db, kind: kind) }
    }

    // MARK: - Songs

    func songs(sort: SongSort = .title, search: String = "", limit: Int? = nil) -> LiveQuery<[Song]> {
        let isSearch = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return query("songs:\(sort.rawValue):\(search):\(limit ?? 0)", initial: [Song](), isSearch: isSearch) { db in
            try LibraryQueries.songs(db, sort: sort, search: search, limit: limit)
        }
    }

    func favoriteSongs() -> LiveQuery<[Song]> {
        query("favoriteSongs", initial: [Song]()) { db in try LibraryQueries.favoriteSongs(db) }
    }

    func songs(artistId: String) -> LiveQuery<[Song]> {
        query("songsByArtist:\(artistId)", initial: [Song]()) { db in try LibraryQueries.songs(db, artistId: artistId) }
    }

    func songs(genre: String, limit: Int? = nil) -> LiveQuery<[Song]> {
        query("songsByGenre:\(genre):\(limit ?? 0)", initial: [Song]()) { db in
            try LibraryQueries.songs(db, genre: genre, limit: limit)
        }
    }

    /// Top songs for an artist: fetched from the server once (then refreshed weekly), served from the mirror.
    func topSongs(artistId: String) -> LiveQuery<[Song]> {
        if requestedTopSongs.insert(artistId).inserted {
            Task { await loadTopSongs(artistId: artistId) }
        }
        return query("topSongs:\(artistId)", initial: [Song]()) { db in try LibraryQueries.topSongs(db, artistId: artistId) }
    }

    func recentlyAddedSongs(limit: Int = 50) -> LiveQuery<[Song]> {
        query("recentSongs:\(limit)", initial: [Song]()) { db in try LibraryQueries.recentlyAddedSongs(db, limit: limit) }
    }

    func downloadedSongs() -> LiveQuery<[Song]> {
        query("downloadedSongs", initial: [Song]()) { db in try LibraryQueries.downloadedSongs(db) }
    }

    // MARK: - Playlists, genres, radio, search

    func playlists() -> LiveQuery<[Playlist]> {
        query("playlists", initial: [Playlist]()) { db in try LibraryQueries.playlists(db) }
    }

    func playlist(id: String) -> LiveQuery<Playlist?> {
        query("playlist:\(id)", initial: Playlist?.none) { db in try LibraryQueries.playlist(db, id: id) }
    }

    func playlistSongs(id: String) -> LiveQuery<[Song]> {
        query("playlistSongs:\(id)", initial: [Song]()) { db in try LibraryQueries.playlistSongs(db, id: id) }
    }

    func genres() -> LiveQuery<[Genre]> {
        query("genres", initial: [Genre]()) { db in try LibraryQueries.genres(db) }
    }

    func radioStations() -> LiveQuery<[RadioStation]> {
        query("radio", initial: [RadioStation]()) { db in try LibraryQueries.radioStations(db) }
    }

    func counts() -> LiveQuery<LibraryCounts> {
        query("counts", initial: LibraryCounts()) { db in try LibraryQueries.counts(db) }
    }

    /// Search across artists, albums and songs (FTS5 prefix search with substring fallback).
    func search(_ text: String) -> LiveQuery<SearchResults> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return query("search:\(t)", initial: SearchResults.empty) { db in try LibraryQueries.search(db, text: t) }
    }

    // MARK: - One-shot lookups

    func songs(ids: [String]) async -> [Song] {
        guard let database, !ids.isEmpty else { return [] }
        do {
            return try await database.pool.read { db in try LibraryQueries.songs(db, ids: ids) }
        } catch {
            Log.database.error("Failed to read songs(\(ids)): \(error)")
            return []
        }
    }

    func song(id: String) async -> Song? {
        await songs(ids: [id]).first
    }

    func albumContent(id: String) async -> AlbumContent {
        guard let database else { return AlbumContent() }
        do {
            return try await database.pool.read { db in try LibraryQueries.album(db, id: id) }
        } catch {
            Log.database.error("Failed to read albumContent(\(id)): \(error)")
            return AlbumContent()
        }
    }

    // MARK: - Lyrics & artist info (DB first, then server)

    func lyrics(songId: String) async -> [StructuredLyrics] {
        guard let database else { return [] }
        let cached: (json: String, fetchedAt: Date)?
        do {
            cached = try await database.pool.read { db -> (json: String, fetchedAt: Date)? in
                guard let row = try Row.fetchOne(db, sql: "SELECT json, fetchedAt FROM lyrics WHERE songId = ?", arguments: [songId]) else { return nil }
                let json: String = row["json"]
                let fetchedAt: Date = row["fetchedAt"]
                return (json, fetchedAt)
            }
        } catch {
            Log.database.warning("Reading cached lyrics for \(songId) failed: \(error)")
            cached = nil
        }
        let decoder = JSONDecoder()
        if let cached, let data = cached.json.data(using: .utf8),
           let lines = try? decoder.decode([StructuredLyrics].self, from: data) {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            // Found lyrics are kept; "none" is re-checked after a week.
            if !lines.isEmpty || age < 7 * 86400 || isOfflineProvider() { return lines }
        }
        guard let client, !isOfflineProvider() else { return [] }
        do {
            let fetched = try await client.getLyricsBySongId(id: songId)
            do {
                if let data = try? JSONEncoder().encode(fetched), let json = String(data: data, encoding: .utf8) {
                    try await database.pool.write { db in
                        try db.execute(
                            sql: "INSERT INTO lyrics(songId, json, fetchedAt) VALUES (?, ?, ?) ON CONFLICT(songId) DO UPDATE SET json = excluded.json, fetchedAt = excluded.fetchedAt",
                            arguments: [songId, json, Date()]
                        )
                    }
                }
            } catch {
                Log.database.warning("Caching lyrics for \(songId) failed: \(error)")
            }
            return fetched
        } catch {
            Log.sync.warning("lyrics(\(songId)) failed: \(error.localizedDescription)")
            return []
        }
    }

    func artistInfo(artistId: String) async -> ArtistInfo? {
        guard let database else { return nil }
        let cached: (json: String, fetchedAt: Date)?
        do {
            cached = try await database.pool.read { db -> (json: String, fetchedAt: Date)? in
                guard let row = try Row.fetchOne(db, sql: "SELECT json, fetchedAt FROM artistInfo WHERE artistId = ?", arguments: [artistId]) else { return nil }
                let json: String = row["json"]
                let fetchedAt: Date = row["fetchedAt"]
                return (json, fetchedAt)
            }
        } catch {
            Log.database.warning("Reading cached artistInfo for \(artistId) failed: \(error)")
            cached = nil
        }
        let stored: ArtistInfo? = cached.flatMap { $0.json.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ArtistInfo.self, from: $0) }
        if let stored, let cached, Date().timeIntervalSince(cached.fetchedAt) < 14 * 86400 || isOfflineProvider() { return stored }
        guard let client, !isOfflineProvider() else { return stored }
        do {
            let info = try await client.getArtistInfo2(id: artistId)
            do {
                if let data = try? JSONEncoder().encode(info), let json = String(data: data, encoding: .utf8) {
                    try await database.pool.write { db in
                        try db.execute(
                            sql: "INSERT INTO artistInfo(artistId, json, fetchedAt) VALUES (?, ?, ?) ON CONFLICT(artistId) DO UPDATE SET json = excluded.json, fetchedAt = excluded.fetchedAt",
                            arguments: [artistId, json, Date()]
                        )
                    }
                }
            } catch {
                Log.database.warning("Caching artistInfo for \(artistId) failed: \(error)")
            }
            return info
        } catch {
            Log.sync.warning("artistInfo(\(artistId)) failed: \(error.localizedDescription)")
            return stored
        }
    }

    private func loadTopSongs(artistId: String) async {
        guard let database, let client, !isOfflineProvider() else { return }
        let key = "topSongs.\(artistId)"
        if let raw = await database.stateValue(key), let t = TimeInterval(raw), Date().timeIntervalSince1970 - t < 7 * 86400 { return }
        do {
            guard let name = try await database.pool.read({ db in try LibraryQueries.artist(db, id: artistId)?.name }) else { return }
            let songs = try await client.getTopSongs(artistName: name, artistId: artistId, count: 20)
            try await database.pool.write { db in
                for song in songs { try song.upsert(db) }
                try db.execute(sql: "DELETE FROM topSong WHERE artistId = ?", arguments: [artistId])
                for (index, song) in songs.enumerated() {
                    try db.execute(sql: "INSERT INTO topSong(artistId, position, songId) VALUES (?, ?, ?)", arguments: [artistId, index, song.id])
                }
            }
            await database.setStateValue(String(Date().timeIntervalSince1970), for: key)
        } catch {
            Log.sync.warning("topSongs(\(artistId)) failed: \(error.localizedDescription)")
            requestedTopSongs.remove(artistId)
        }
    }

    // MARK: - Local play stats

    /// Reflects a completed play in the mirror immediately (the server updates on scrobble).
    func markPlayed(songId: String, at date: Date = Date()) async {
        guard let database else { return }
        do {
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE song SET played = ?, playCount = COALESCE(playCount, 0) + 1 WHERE id = ?", arguments: [date, songId])
                try db.execute(
                    sql: "UPDATE album SET played = ?, playCount = COALESCE(playCount, 0) + 1 WHERE id = (SELECT albumId FROM song WHERE id = ?)",
                    arguments: [date, songId]
                )
            }
        } catch {
            Log.database.warning("markPlayed failed for \(songId): \(error)")
        }
    }

    // MARK: - Mutations: favorites & ratings

    private func table(for kind: StarKind) -> String {
        switch kind {
        case .song: return "song"
        case .album: return "album"
        case .artist: return "artist"
        }
    }

    private func requireClient() throws -> SubsonicClient {
        guard let client else { throw LibraryError.notSignedIn }
        if isOfflineProvider() { throw LibraryError.offline }
        return client
    }

    private func requireDatabase() throws -> LibraryDatabase {
        guard let database else { throw LibraryError.notSignedIn }
        return database
    }

    /// Optimistic: the heart flips immediately, and flips back if the server rejects it.
    func setStarred(_ kind: StarKind, id: String, _ on: Bool) async throws {
        let client = try requireClient()
        let database = try requireDatabase()
        let table = table(for: kind)
        let previous: Date? = try await database.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT starred FROM \(table) WHERE id = ?", arguments: [id])
        }
        try await write(database, "UPDATE \(table) SET starred = ? WHERE id = ?", [on ? Date() : nil, id])
        do {
            switch (kind, on) {
            case (.song, true): try await client.star(id: id)
            case (.song, false): try await client.unstar(id: id)
            case (.album, true): try await client.star(albumId: id)
            case (.album, false): try await client.unstar(albumId: id)
            case (.artist, true): try await client.star(artistId: id)
            case (.artist, false): try await client.unstar(artistId: id)
            }
            if kind == .song {
                onSongStarChanged?(id, on)
            }
        } catch {
            do {
                try await write(database, "UPDATE \(table) SET starred = ? WHERE id = ?", [previous, id])
            } catch let rollbackError {
                Log.database.error("Rollback starred failed for \(id): \(rollbackError)")
            }
            report(error, "Could not update favorite")
            throw error
        }
    }

    func toggleStar(_ kind: StarKind, id: String, currentlyStarred: Bool) async throws {
        try await setStarred(kind, id: id, !currentlyStarred)
    }

    /// Updates only the local mirror row for a song's star status (used when the server has already been notified).
    func applyLocalStar(songId: String, starred: Bool) async {
        guard let database else { return }
        do {
            try await write(database, "UPDATE song SET starred = ? WHERE id = ?", [starred ? Date() : nil, songId])
        } catch {
            Log.database.error("applyLocalStar failed for \(songId): \(error)")
        }
    }

    /// Rating 0...5 (0 clears). Songs and albums.
    func setRating(_ kind: StarKind, id: String, rating: Int) async throws {
        guard kind != .artist else { return }
        let client = try requireClient()
        let database = try requireDatabase()
        let table = table(for: kind)
        let value = max(0, min(5, rating))
        let previous: Int? = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT userRating FROM \(table) WHERE id = ?", arguments: [id])
        }
        try await write(database, "UPDATE \(table) SET userRating = ? WHERE id = ?", [value == 0 ? nil : value, id])
        do {
            try await client.setRating(id: id, rating: value)
        } catch {
            do {
                try await write(database, "UPDATE \(table) SET userRating = ? WHERE id = ?", [previous, id])
            } catch let rollbackError {
                Log.database.error("Rollback userRating failed for \(id): \(rollbackError)")
            }
            report(error, "Could not save rating")
            throw error
        }
    }

    // MARK: - Mutations: playlists

    @discardableResult
    func createPlaylist(name: String, songIds: [String] = []) async throws -> Playlist {
        let client = try requireClient()
        let database = try requireDatabase()
        do {
            let (playlist, songs) = try await client.createPlaylist(name: name, songIds: songIds)
            if songs.isEmpty && !songIds.isEmpty {
                try await refreshPlaylist(id: playlist.id)
            } else {
                try await database.storePlaylist(playlist, songs: songs)
            }
            return playlist
        } catch {
            report(error, "Could not create playlist")
            throw error
        }
    }

    /// Creates the playlist `name`, or replaces its songs when it exists (no-op when already identical).
    @discardableResult
    func upsertPlaylist(named name: String, songIds: [String]) async throws -> Playlist {
        let client = try requireClient()
        let database = try requireDatabase()
        let existing = try await database.pool.read { db in try LibraryQueries.playlists(db) }.first { $0.name == name }
        if let existing, try await playlistSongIds(database, id: existing.id) == songIds { return existing }
        let (playlist, songs) = try await client.createPlaylist(name: existing == nil ? name : nil,
                                                                playlistId: existing?.id, songIds: songIds)
        if songs.isEmpty && !songIds.isEmpty {
            try await refreshPlaylist(id: playlist.id)
        } else {
            try await database.storePlaylist(playlist, songs: songs)
        }
        return playlist
    }

    func renamePlaylist(id: String, name: String) async throws {
        let client = try requireClient()
        let database = try requireDatabase()
        do {
            try await client.updatePlaylist(id: id, name: name)
            try await write(database, "UPDATE playlist SET name = ? WHERE id = ?", [name, id])
        } catch {
            report(error, "Could not rename playlist")
            throw error
        }
    }

    func deletePlaylist(id: String) async throws {
        let client = try requireClient()
        let database = try requireDatabase()
        do {
            try await client.deletePlaylist(id: id)
            try await database.pool.write { db in
                try db.execute(sql: "DELETE FROM playlistEntry WHERE playlistId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id])
            }
        } catch {
            report(error, "Could not delete playlist")
            throw error
        }
    }

    func addToPlaylist(id: String, songIds: [String]) async throws {
        guard !songIds.isEmpty else { return }
        let client = try requireClient()
        do {
            try await client.updatePlaylist(id: id, songIdsToAdd: songIds)
            try await refreshPlaylist(id: id)
        } catch {
            report(error, "Could not add to playlist")
            throw error
        }
    }

    /// `indexes` are positions in the playlist (0-based, as displayed).
    func removeFromPlaylist(id: String, indexes: [Int]) async throws {
        guard !indexes.isEmpty else { return }
        let client = try requireClient()
        let database = try requireDatabase()
        let removed = Set(indexes)
        let before = try await playlistSongIds(database, id: id)
        try await replaceEntries(database, playlistId: id, songIds: before.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
        do {
            try await client.updatePlaylist(id: id, songIndexesToRemove: indexes)
        } catch {
            do {
                try await replaceEntries(database, playlistId: id, songIds: before)
            } catch let rollbackError {
                Log.database.error("Rollback removeFromPlaylist failed for \(id): \(rollbackError)")
            }
            report(error, "Could not remove from playlist")
            throw error
        }
    }

    /// Reorders entries (SwiftUI `onMove` semantics: `destination` is the index in the original array).
    func movePlaylistEntries(id: String, from source: IndexSet, to destination: Int) async throws {
        let client = try requireClient()
        let database = try requireDatabase()
        let before = try await playlistSongIds(database, id: id)
        var items = before
        let moving = source.sorted().compactMap { $0 < items.count ? items[$0] : nil }
        for index in source.sorted().reversed() where index < items.count { items.remove(at: index) }
        let shift = source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: max(0, min(items.count, destination - shift)))
        try await replaceEntries(database, playlistId: id, songIds: items)
        do {
            try await client.createPlaylist(playlistId: id, songIds: items)
        } catch {
            do {
                try await replaceEntries(database, playlistId: id, songIds: before)
            } catch let rollbackError {
                Log.database.error("Rollback movePlaylistEntries failed for \(id): \(rollbackError)")
            }
            report(error, "Could not reorder playlist")
            throw error
        }
    }

    func refreshPlaylist(id: String) async throws {
        let client = try requireClient()
        let database = try requireDatabase()
        let (playlist, songs) = try await client.getPlaylist(id: id)
        try await database.storePlaylist(playlist, songs: songs)
    }

    // MARK: - Sync-related actions

    /// Asks the server to rescan, waits for it to finish, then re-syncs the mirror.
    func startScan(full: Bool) async throws {
        let client = try requireClient()
        do {
            try await client.startScan(fullScan: full)
            for _ in 0..<150 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let scan = try await client.getScanStatus()
                if !scan.scanning { break }
            }
            await syncEngine?.sync(force: true)
        } catch {
            report(error, "Scan failed")
            throw error
        }
    }

    func refreshHomeLists() async {
        do {
            try await syncEngine?.refreshHomeLists()
        } catch {
            Log.sync.warning("refreshHomeLists failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    func report(_ error: Error, _ prefix: String) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.sync.error("\(prefix): \(error)")
        lastError = "\(prefix). \(detail)"
    }

    private func write(_ database: LibraryDatabase, _ sql: String, _ arguments: [(any DatabaseValueConvertible)?]) async throws {
        try await database.pool.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(arguments))
        }
    }

    private func playlistSongIds(_ database: LibraryDatabase, id: String) async throws -> [String] {
        try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT songId FROM playlistEntry WHERE playlistId = ? ORDER BY position", arguments: [id])
        }
    }

    private func replaceEntries(_ database: LibraryDatabase, playlistId: String, songIds: [String]) async throws {
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM playlistEntry WHERE playlistId = ?", arguments: [playlistId])
            for (index, songId) in songIds.enumerated() {
                try PlaylistEntry(playlistId: playlistId, position: index, songId: songId).insert(db)
            }
            try db.execute(sql: "UPDATE playlist SET songCount = ? WHERE id = ?", arguments: [songIds.count, playlistId])
        }
    }
}
