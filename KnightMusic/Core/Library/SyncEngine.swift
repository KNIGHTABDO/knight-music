import Foundation
import GRDB

/// Mirrors the server library into the local database.
/// - Full pass (first login, or when the server's `lastScan` changed): artists, albums, songs with mark-and-sweep.
/// - Cheap pass (every launch / foreground / pull-to-refresh): playlists, starred, genres, radio, home shelves.
actor SyncEngine {
    private let database: LibraryDatabase
    private var client: SubsonicClient
    private let status: SyncStatus
    private var inflight: Task<Bool, Never>?
    private var softErrors: [String] = []

    private static let pageSize = 500

    init(database: LibraryDatabase, client: SubsonicClient, status: SyncStatus) {
        self.database = database
        self.client = client
        self.status = status
    }

    func setClient(_ client: SubsonicClient) { self.client = client }

    func cancel() { inflight?.cancel() }

    /// Runs an incremental sync (or joins the one in flight). Returns true if the server was reached and the
    /// pass completed. `force` re-reads the whole library even if the server reports no change.
    @discardableResult
    func sync(force: Bool = false) async -> Bool {
        if let inflight { return await inflight.value }
        let task = Task { await self.run(force: force) }
        inflight = task
        let ok = await task.value
        inflight = nil
        return ok
    }

    /// Refreshes only the home shelves (also upserts the albums they reference, which carries play counts).
    func refreshHomeLists() async throws {
        try await syncHomeLists(client: client)
    }

    func refreshPlaylist(id: String) async throws {
        let (playlist, songs) = try await client.getPlaylist(id: id)
        try await database.storePlaylist(playlist, songs: songs)
    }

    // MARK: - Orchestration

    private func run(force: Bool) async -> Bool {
        let client = self.client
        softErrors = []
        let started = Date()
        let songCount = await countRows("song")
        let isInitial: Bool
        if let songCount {
            isInitial = songCount == 0
        } else {
            Log.sync.error("failed to determine song count; treating as non-initial sync")
            isInitial = false
        }
        await status.begin(phase: isInitial ? "Connecting…" : "Checking for changes…", initial: isInitial)
        Log.sync.info("sync started (force=\(force), initial=\(isInitial))")

        do {
            let scan = try await client.getScanStatus()
            let scanToken = scan.lastScan.map { String($0.timeIntervalSince1970) } ?? "none"
            let storedScan = await database.stateValue(SyncKey.lastScan)
            let lastLibrarySync = await database.stateValue(SyncKey.lastLibrarySync).flatMap(TimeInterval.init)
            let lastFullLibrarySync = await database.stateValue(SyncKey.lastFullLibrarySync).flatMap(TimeInterval.init)

            let isFullDue = lastFullLibrarySync.map { Date().timeIntervalSince1970 - $0 > 24 * 3600 } ?? true
            let requiresFullPass = force || isInitial || isFullDue

            var scanChanged = storedScan != scanToken
            if scan.lastScan == nil, let last = lastLibrarySync, Date().timeIntervalSince1970 - last > 6 * 3600 {
                scanChanged = true
            }

            var libraryPassRan = false
            if requiresFullPass {
                Log.sync.info("running full library pass (force=\(force), initial=\(isInitial), fullDue=\(isFullDue))")
                try await syncLibrary(client: client)
                let now = Date().timeIntervalSince1970
                await database.setStateValue(scanToken, for: SyncKey.lastScan)
                await database.setStateValue(String(now), for: SyncKey.lastLibrarySync)
                await database.setStateValue(String(now), for: SyncKey.lastFullLibrarySync)
                libraryPassRan = true
            } else if scanChanged {
                Log.sync.info("running incremental library pass (scan changed: stored=\(storedScan ?? "nil") new=\(scanToken))")
                try await syncLibraryIncremental(client: client)
                let now = Date().timeIntervalSince1970
                await database.setStateValue(scanToken, for: SyncKey.lastScan)
                await database.setStateValue(String(now), for: SyncKey.lastLibrarySync)
                libraryPassRan = true
            } else {
                Log.sync.info("library unchanged since last scan")
            }
            try await syncCheap(client: client, startFraction: libraryPassRan ? 0.9 : 0.1)
        } catch is CancellationError {
            Log.sync.info("sync cancelled")
            await status.finish(error: nil, completedAt: nil)
            return false
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.sync.error("sync failed: \(error)")
            await status.finish(error: message, completedAt: nil)
            return false
        }

        let now = Date()
        await database.setStateValue(String(now.timeIntervalSince1970), for: SyncKey.lastSyncAt)
        await status.finish(error: softErrors.first, completedAt: now)
        Log.sync.info("sync finished in \(String(format: "%.1f", now.timeIntervalSince(started)))s")
        return true
    }

    // MARK: - Library pass

    private func syncLibrary(client: SubsonicClient) async throws {
        let size = Self.pageSize

        await status.update(phase: "Syncing artists…", fraction: 0.02)
        let artists = try await client.getArtists()
        try await database.pool.write { db in
            _ = try writeChanged(artists, in: db, same: sameArtist)
        }
        let removedArtists = try await sweep("artist", keeping: Set(artists.map(\.id)))
        Log.sync.info("artists: \(artists.count) (removed \(removedArtists))")
        let expectedAlbums = artists.reduce(0) { $0 + ($1.albumCount ?? 0) }

        await status.update(phase: "Syncing albums…", fraction: 0.06)
        var albumIds = Set<String>()
        var expectedSongs = 0
        try await paged(size: size, fetch: { offset in
            try await client.getAlbumList2(type: .alphabeticalByName, size: size, offset: offset)
        }, handle: { page in
            try await self.database.pool.write { db in
                _ = try writeChanged(page, in: db, same: sameAlbum)
            }
            albumIds.formUnion(page.map(\.id))
            expectedSongs += page.reduce(0) { $0 + ($1.songCount ?? 0) }
            let progress = expectedAlbums > 0 ? Double(albumIds.count) / Double(max(expectedAlbums, albumIds.count)) : 0.5
            await self.status.update(phase: "Syncing albums… \(albumIds.count)", fraction: 0.06 + 0.24 * progress)
        })
        if guardSweep(seen: albumIds.count, expected: expectedAlbums, ratio: 0.9, what: "albums") {
            let removed = try await sweep("album", keeping: albumIds)
            Log.sync.info("albums: \(albumIds.count) (removed \(removed))")
        }

        await status.update(phase: "Syncing songs…", fraction: 0.3)
        var songIds = Set<String>()
        try await paged(size: size, fetch: { offset in
            try await client.search3(query: "", artistCount: 0, albumCount: 0, songCount: size, songOffset: offset).songs
        }, handle: { page in
            try await self.database.pool.write { db in
                _ = try writeChanged(page, in: db, same: sameSong)
            }
            songIds.formUnion(page.map(\.id))
            let progress = expectedSongs > 0 ? Double(songIds.count) / Double(max(expectedSongs, songIds.count)) : 0.5
            await self.status.update(phase: "Syncing songs… \(songIds.count)", fraction: 0.3 + 0.6 * progress)
        })
        if guardSweep(seen: songIds.count, expected: expectedSongs, what: "songs") {
            let removed = try await sweep("song", keeping: songIds)
            Log.sync.info("songs: \(songIds.count) (removed \(removed))")
        }
    }

    private func syncLibraryIncremental(client: SubsonicClient) async throws {
        let size = Self.pageSize

        await status.update(phase: "Syncing artists…", fraction: 0.02)
        let artists = try await client.getArtists()
        try await database.pool.write { db in
            _ = try writeChanged(artists, in: db, same: sameArtist)
        }
        let removedArtists = try await sweep("artist", keeping: Set(artists.map(\.id)))
        Log.sync.info("artists: \(artists.count) (removed \(removedArtists))")
        let expectedAlbums = artists.reduce(0) { $0 + ($1.albumCount ?? 0) }

        await status.update(phase: "Syncing albums…", fraction: 0.06)
        var albumIds = Set<String>()
        var changedAlbums: [Album] = []
        try await paged(size: size, fetch: { offset in
            try await client.getAlbumList2(type: .alphabeticalByName, size: size, offset: offset)
        }, handle: { page in
            let stored = try await self.database.pool.read { db in
                try Album.fetchAll(db, keys: page.map(\.id))
            }
            let storedById = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let pageChanged = page.filter { isAlbumContentChanged(new: $0, old: storedById[$0.id]) }
            changedAlbums.append(contentsOf: pageChanged)

            try await self.database.pool.write { db in
                _ = try writeChanged(page, in: db, same: sameAlbum)
            }
            albumIds.formUnion(page.map(\.id))
            let progress = expectedAlbums > 0 ? Double(albumIds.count) / Double(max(expectedAlbums, albumIds.count)) : 0.5
            await self.status.update(phase: "Syncing albums… \(albumIds.count)", fraction: 0.06 + 0.34 * progress)
        })

        if guardSweep(seen: albumIds.count, expected: expectedAlbums, ratio: 0.9, what: "albums") {
            let removed = try await sweep("album", keeping: albumIds)
            Log.sync.info("albums: \(albumIds.count) (removed \(removed))")
            if removed > 0 {
                try await database.pool.write { db in
                    try db.execute(sql: "DELETE FROM song WHERE albumId NOT IN (SELECT id FROM album)")
                }
            }
        }

        await status.update(phase: "Syncing songs…", fraction: 0.4)
        if changedAlbums.isEmpty {
            Log.sync.info("incremental: no album content changes (0 songs fetched)")
            await status.update(phase: "Syncing songs… 0", fraction: 0.9)
        } else {
            Log.sync.info("incremental: \(changedAlbums.count) content-changed albums, fetching songs…")
            var completedCount = 0
            for batch in changedAlbums.chunked(into: 4) {
                try Task.checkCancellation()
                let results = try await withThrowingTaskGroup(of: (Album, [Song]).self) { group in
                    for album in batch {
                        group.addTask {
                            try await client.getAlbum(id: album.id)
                        }
                    }
                    var out: [(Album, [Song])] = []
                    for try await r in group { out.append(r) }
                    return out
                }
                try await database.pool.write { db in
                    for (album, songs) in results {
                        _ = try writeChanged(songs, in: db, same: sameSong)
                        try populateKeepIds(db, keeping: Set(songs.map(\.id)))
                        try db.execute(
                            sql: "DELETE FROM song WHERE albumId = ? AND id NOT IN (SELECT id FROM keep_ids)",
                            arguments: [album.id]
                        )
                    }
                }
                completedCount += batch.count
                let progress = Double(completedCount) / Double(changedAlbums.count)
                await status.update(
                    phase: "Syncing songs… \(completedCount)/\(changedAlbums.count)",
                    fraction: 0.4 + 0.5 * progress
                )
            }
            Log.sync.info("incremental: refreshed songs for \(changedAlbums.count) albums")
        }
    }

    /// Only delete rows when the pass clearly saw (almost) everything the server advertised.
    private func guardSweep(seen: Int, expected: Int, ratio: Double = 0.98, what: String) -> Bool {
        if expected == 0 { return seen > 0 }
        if Double(seen) >= Double(expected) * ratio { return true }
        Log.sync.warning("skipping sweep of \(what): saw \(seen) of ~\(expected)")
        return false
    }

    /// Fetches pages concurrently (a few at a time) and hands them over in order.
    private func paged<T: Sendable>(
        size: Int,
        concurrency: Int = 3,
        fetch: @escaping @Sendable (Int) async throws -> [T],
        handle: ([T]) async throws -> Void
    ) async throws {
        var offset = 0
        var finished = false
        while !finished {
            try Task.checkCancellation()
            let offsets = (0..<concurrency).map { offset + $0 * size }
            let pages: [[T]] = try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
                for (i, o) in offsets.enumerated() {
                    group.addTask { (i, try await fetch(o)) }
                }
                var out = Array(repeating: [T](), count: offsets.count)
                for try await (i, page) in group { out[i] = page }
                return out
            }
            for page in pages {
                if page.isEmpty { finished = true; break }
                try await handle(page)
                if page.count < size { finished = true; break }
            }
            offset += concurrency * size
        }
    }

    private func sweep(_ table: String, keeping seen: Set<String>) async throws -> Int {
        try await database.pool.write { db in
            try populateKeepIds(db, keeping: seen)
            try db.execute(sql: "DELETE FROM \(table) WHERE id NOT IN (SELECT id FROM keep_ids)")
            return db.changesCount
        }
    }

    private func countRows(_ table: String) async -> Int? {
        do {
            return try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
        } catch {
            Log.sync.error("countRows(\(table)) failed: \(error)")
            return nil
        }
    }

    // MARK: - Cheap pass

    private func syncCheap(client: SubsonicClient, startFraction: Double) async throws {
        await status.update(phase: "Updating playlists…", fraction: startFraction)
        try await soft("playlists") { try await self.syncPlaylists(client: client) }
        await status.update(phase: "Updating favorites…", fraction: startFraction + (1 - startFraction) * 0.4)
        try await soft("starred") { try await self.syncStarred(client: client) }
        await status.update(phase: "Updating genres…", fraction: startFraction + (1 - startFraction) * 0.6)
        try await soft("genres") { try await self.syncGenres(client: client) }
        try await soft("radio") { try await self.syncRadio(client: client) }
        await status.update(phase: "Updating home…", fraction: startFraction + (1 - startFraction) * 0.8)
        try await soft("home") { try await self.syncHomeLists(client: client) }
    }

    /// Non-transport failures of one step are logged and surfaced but don't abort the others.
    private func soft(_ name: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubsonicError where error.isTransport {
            throw error
        } catch {
            Log.sync.error("\(name) sync failed: \(error)")
            softErrors.append("\(name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    private func syncPlaylists(client: SubsonicClient) async throws {
        let remote = try await client.getPlaylists()
        let local: [String: Playlist] = try await database.pool.read { db in
            let rows = try Playlist.fetchAll(db)
            return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let entryCounts: [String: Int] = try await database.pool.read { db in
            var out: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT playlistId, COUNT(*) AS n FROM playlistEntry GROUP BY playlistId") {
                let id: String = row["playlistId"]
                let n: Int = row["n"]
                out[id] = n
            }
            return out
        }

        try await database.pool.write { db in
            _ = try writeChanged(remote, in: db, same: samePlaylist)
        }
        let removedPlaylists = try await sweep("playlist", keeping: Set(remote.map(\.id)))
        if removedPlaylists > 0 {
            try await database.pool.write { db in
                try db.execute(sql: "DELETE FROM playlistEntry WHERE playlistId NOT IN (SELECT id FROM playlist)")
            }
        }

        let stale = remote.filter { p in
            guard let l = local[p.id] else { return true }
            return !sameInstant(l.changed, p.changed) || l.songCount != p.songCount || (entryCounts[p.id] ?? 0) != (p.songCount ?? 0)
        }
        for batch in stale.chunked(into: 4) {
            try Task.checkCancellation()
            let results = try await withThrowingTaskGroup(of: (Playlist, [Song]).self) { group in
                for p in batch { group.addTask { try await client.getPlaylist(id: p.id) } }
                var out: [(Playlist, [Song])] = []
                for try await r in group { out.append(r) }
                return out
            }
            for (playlist, songs) in results {
                try await database.storePlaylist(playlist, songs: songs)
            }
        }
        Log.sync.info("playlists: \(remote.count) (refreshed \(stale.count))")
    }

    private func syncStarred(client: SubsonicClient) async throws {
        let items = try await client.getStarred2()
        try await database.pool.write { db in
            _ = try writeChanged(items.artists, in: db, same: sameArtist)
            _ = try writeChanged(items.albums, in: db, same: sameAlbum)
            _ = try writeChanged(items.songs, in: db, same: sameSong)
            _ = try clearStaleStars(db, table: "artist", keep: Set(items.artists.map(\.id)))
            _ = try clearStaleStars(db, table: "album", keep: Set(items.albums.map(\.id)))
            _ = try clearStaleStars(db, table: "song", keep: Set(items.songs.map(\.id)))
        }
    }

    private func syncGenres(client: SubsonicClient) async throws {
        let genres = try await client.getGenres()
        let validGenres = genres.filter { !$0.value.isEmpty }
        try await database.pool.write { db in
            let keepValues = Set(validGenres.map(\.value))
            try populateKeepIds(db, keeping: keepValues)
            try db.execute(sql: "DELETE FROM genre WHERE value NOT IN (SELECT id FROM keep_ids)")
            _ = try writeChanged(validGenres, in: db, same: sameGenre)
        }
    }

    private func syncRadio(client: SubsonicClient) async throws {
        let stations = try await client.getInternetRadioStations()
        try await database.pool.write { db in
            let keepIds = Set(stations.map(\.id))
            try populateKeepIds(db, keeping: keepIds)
            try db.execute(sql: "DELETE FROM radioStation WHERE id NOT IN (SELECT id FROM keep_ids)")
            _ = try writeChanged(stations, in: db, same: sameRadioStation)
        }
    }

    private func syncHomeLists(client: SubsonicClient) async throws {
        let lists = try await withThrowingTaskGroup(of: (HomeKind, [Album]).self) { group in
            for kind in HomeKind.allCases {
                group.addTask { (kind, try await client.getAlbumList2(type: kind.albumListType, size: kind.size)) }
            }
            var out: [(HomeKind, [Album])] = []
            for try await r in group { out.append(r) }
            return out
        }
        for (kind, albums) in lists {
            try await database.storeHomeList(kind, albums: albums)
        }
    }
}

@discardableResult
private func clearStaleStars(_ db: Database, table: String, keep: Set<String>) throws -> Int {
    try populateKeepIds(db, keeping: keep)
    try db.execute(sql: "UPDATE \(table) SET starred = NULL WHERE starred IS NOT NULL AND id NOT IN (SELECT id FROM keep_ids)")
    return db.changesCount
}
