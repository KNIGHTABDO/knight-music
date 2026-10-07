import Foundation
import GRDB

/// Pure read functions over the mirror. Each takes a `Database` so it can run inside a ValueObservation.
enum LibraryQueries {
    // MARK: - Helpers

    /// `%text%` with LIKE wildcards escaped (use with `ESCAPE '\'`).
    static func likePattern(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%" + escaped + "%"
    }

    /// FTS5 MATCH expression: every word becomes a quoted prefix term ("word"*), ANDed together. Nil if there are no words.
    static func ftsPattern(_ text: String) -> String? {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Artists

    static func artists(_ db: Database, search: String) throws -> [Artist] {
        let q = trimmed(search)
        if q.isEmpty {
            return try Artist.fetchAll(db, sql: "SELECT * FROM artist ORDER BY name COLLATE NOCASE")
        }
        return try Artist.fetchAll(
            db,
            sql: "SELECT * FROM artist WHERE name LIKE ? ESCAPE '\\' ORDER BY name COLLATE NOCASE",
            arguments: [likePattern(q)]
        )
    }

    static func favoriteArtists(_ db: Database) throws -> [Artist] {
        try Artist.fetchAll(db, sql: "SELECT * FROM artist WHERE starred IS NOT NULL ORDER BY starred DESC")
    }

    static func artist(_ db: Database, id: String) throws -> Artist? {
        try Artist.fetchOne(db, sql: "SELECT * FROM artist WHERE id = ?", arguments: [id])
    }

    // MARK: - Albums

    private static func albumOrder(_ sort: AlbumSort) -> (where: String, order: String) {
        switch sort {
        case .name: return ("", "album.name COLLATE NOCASE")
        case .artist: return ("", "album.artist COLLATE NOCASE, album.year, album.name COLLATE NOCASE")
        case .year: return ("", "album.year DESC, album.name COLLATE NOCASE")
        case .recentlyAdded: return ("", "album.created DESC, album.name COLLATE NOCASE")
        case .mostPlayed: return ("album.playCount > 0", "album.playCount DESC, album.played DESC")
        case .recentlyPlayed: return ("album.played IS NOT NULL", "album.played DESC")
        }
    }

    static func albums(_ db: Database, sort: AlbumSort, search: String, limit: Int?) throws -> [Album] {
        let spec = albumOrder(sort)
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []
        if !spec.where.isEmpty { clauses.append(spec.where) }
        let q = trimmed(search)
        let pattern = q.isEmpty ? nil : ftsPattern(q)
        var sql: String
        if let pattern {
            sql = "SELECT album.* FROM album JOIN albumFts ON albumFts.rowid = album.rowid"
            clauses.append("albumFts MATCH ?")
            args.append(pattern)
        } else {
            sql = "SELECT album.* FROM album"
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY " + spec.order
        if let limit { sql += " LIMIT \(limit)" }
        return try Album.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    static func favoriteAlbums(_ db: Database) throws -> [Album] {
        try Album.fetchAll(db, sql: "SELECT * FROM album WHERE starred IS NOT NULL ORDER BY starred DESC")
    }

    static func albums(_ db: Database, artistId: String) throws -> [Album] {
        try Album.fetchAll(
            db,
            sql: "SELECT * FROM album WHERE artistId = ? ORDER BY year DESC, name COLLATE NOCASE",
            arguments: [artistId]
        )
    }

    static func albums(_ db: Database, genre: String) throws -> [Album] {
        try Album.fetchAll(
            db,
            sql: "SELECT * FROM album WHERE genre = ? COLLATE NOCASE ORDER BY name COLLATE NOCASE",
            arguments: [genre]
        )
    }

    static func album(_ db: Database, id: String) throws -> AlbumContent {
        let album = try Album.fetchOne(db, sql: "SELECT * FROM album WHERE id = ?", arguments: [id])
        let songs = try Song.fetchAll(
            db,
            sql: "SELECT * FROM song WHERE albumId = ? ORDER BY COALESCE(discNumber, 1), COALESCE(track, 0), title COLLATE NOCASE",
            arguments: [id]
        )
        return AlbumContent(album: album, songs: songs)
    }

    static func homeList(_ db: Database, kind: HomeKind) throws -> [Album] {
        try Album.fetchAll(
            db,
            sql: """
            SELECT album.* FROM homeList
            JOIN album ON album.id = homeList.albumId
            WHERE homeList.kind = ?
            ORDER BY homeList.position
            """,
            arguments: [kind.rawValue]
        )
    }

    // MARK: - Songs

    private static func songOrder(_ sort: SongSort) -> (where: String, order: String) {
        switch sort {
        case .title: return ("", "song.title COLLATE NOCASE")
        case .artist: return ("", "song.artist COLLATE NOCASE, song.album COLLATE NOCASE, COALESCE(song.discNumber, 1), COALESCE(song.track, 0)")
        case .album: return ("", "song.album COLLATE NOCASE, COALESCE(song.discNumber, 1), COALESCE(song.track, 0)")
        case .year: return ("", "song.year DESC, song.album COLLATE NOCASE, COALESCE(song.discNumber, 1), COALESCE(song.track, 0)")
        case .recentlyAdded: return ("", "song.created DESC, song.title COLLATE NOCASE")
        case .mostPlayed: return ("song.playCount > 0", "song.playCount DESC, song.played DESC")
        case .recentlyPlayed: return ("song.played IS NOT NULL", "song.played DESC")
        }
    }

    static func songs(_ db: Database, sort: SongSort, search: String, limit: Int?) throws -> [Song] {
        let spec = songOrder(sort)
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []
        if !spec.where.isEmpty { clauses.append(spec.where) }
        let q = trimmed(search)
        let pattern = q.isEmpty ? nil : ftsPattern(q)
        var sql: String
        if let pattern {
            sql = "SELECT song.* FROM song JOIN songFts ON songFts.rowid = song.rowid"
            clauses.append("songFts MATCH ?")
            args.append(pattern)
        } else {
            sql = "SELECT song.* FROM song"
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY " + spec.order
        if let limit { sql += " LIMIT \(limit)" }
        return try Song.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    static func favoriteSongs(_ db: Database) throws -> [Song] {
        try Song.fetchAll(db, sql: "SELECT * FROM song WHERE starred IS NOT NULL ORDER BY starred DESC")
    }

    static func songs(_ db: Database, artistId: String) throws -> [Song] {
        try Song.fetchAll(
            db,
            sql: "SELECT * FROM song WHERE artistId = ? ORDER BY album COLLATE NOCASE, COALESCE(discNumber, 1), COALESCE(track, 0)",
            arguments: [artistId]
        )
    }

    static func songs(_ db: Database, genre: String, limit: Int?) throws -> [Song] {
        var sql = "SELECT * FROM song WHERE genre = ? COLLATE NOCASE ORDER BY title COLLATE NOCASE"
        if let limit { sql += " LIMIT \(limit)" }
        return try Song.fetchAll(db, sql: sql, arguments: [genre])
    }

    static func recentlyAddedSongs(_ db: Database, limit: Int) throws -> [Song] {
        try Song.fetchAll(db, sql: "SELECT * FROM song ORDER BY created DESC LIMIT ?", arguments: [limit])
    }

    static func downloadedSongs(_ db: Database) throws -> [Song] {
        try Song.fetchAll(
            db,
            sql: """
            SELECT song.* FROM download
            JOIN song ON song.id = download.songId
            WHERE download.state = 'done'
            ORDER BY download.addedAt DESC
            """
        )
    }

    static func songs(_ db: Database, ids: [String]) throws -> [Song] {
        var byId: [String: Song] = [:]
        for chunk in ids.chunked(into: 500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Song.fetchAll(db, sql: "SELECT * FROM song WHERE id IN (\(marks))", arguments: StatementArguments(chunk.map { $0 as (any DatabaseValueConvertible)? }))
            for s in rows { byId[s.id] = s }
        }
        return ids.compactMap { byId[$0] }
    }

    /// Cached server top songs; falls back to the artist's most played local songs when the server has none.
    static func topSongs(_ db: Database, artistId: String) throws -> [Song] {
        let top = try Song.fetchAll(
            db,
            sql: """
            SELECT song.* FROM topSong
            JOIN song ON song.id = topSong.songId
            WHERE topSong.artistId = ?
            ORDER BY topSong.position
            """,
            arguments: [artistId]
        )
        if !top.isEmpty { return top }
        return try Song.fetchAll(
            db,
            sql: "SELECT * FROM song WHERE artistId = ? AND playCount > 0 ORDER BY playCount DESC, played DESC LIMIT 10",
            arguments: [artistId]
        )
    }

    // MARK: - Playlists, genres, radio

    static func playlists(_ db: Database) throws -> [Playlist] {
        try Playlist.fetchAll(db, sql: "SELECT * FROM playlist ORDER BY name COLLATE NOCASE")
    }

    static func playlist(_ db: Database, id: String) throws -> Playlist? {
        try Playlist.fetchOne(db, sql: "SELECT * FROM playlist WHERE id = ?", arguments: [id])
    }

    static func playlistSongs(_ db: Database, id: String) throws -> [Song] {
        try Song.fetchAll(
            db,
            sql: """
            SELECT song.* FROM playlistEntry
            JOIN song ON song.id = playlistEntry.songId
            WHERE playlistEntry.playlistId = ?
            ORDER BY playlistEntry.position
            """,
            arguments: [id]
        )
    }

    static func genres(_ db: Database) throws -> [Genre] {
        try Genre.fetchAll(db, sql: "SELECT * FROM genre ORDER BY value COLLATE NOCASE")
    }

    static func radioStations(_ db: Database) throws -> [RadioStation] {
        try RadioStation.fetchAll(db, sql: "SELECT * FROM radioStation ORDER BY name COLLATE NOCASE")
    }

    static func counts(_ db: Database) throws -> LibraryCounts {
        LibraryCounts(
            artists: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artist") ?? 0,
            albums: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") ?? 0,
            songs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song") ?? 0,
            playlists: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? 0
        )
    }

    // MARK: - Search

    /// FTS5 prefix search first (ranked), then substring LIKE matches to fill the remaining slots.
    static func search(_ db: Database, text: String, limit: Int = 25) throws -> SearchResults {
        let q = trimmed(text)
        guard !q.isEmpty else { return .empty }
        let match = ftsPattern(q)
        let like = likePattern(q)
        var results = SearchResults()

        if let match {
            results.artists = try Artist.fetchAll(
                db,
                sql: "SELECT artist.* FROM artist JOIN artistFts ON artistFts.rowid = artist.rowid WHERE artistFts MATCH ? ORDER BY bm25(artistFts) LIMIT ?",
                arguments: [match, limit]
            )
            results.albums = try Album.fetchAll(
                db,
                sql: "SELECT album.* FROM album JOIN albumFts ON albumFts.rowid = album.rowid WHERE albumFts MATCH ? ORDER BY bm25(albumFts) LIMIT ?",
                arguments: [match, limit]
            )
            results.songs = try Song.fetchAll(
                db,
                sql: "SELECT song.* FROM song JOIN songFts ON songFts.rowid = song.rowid WHERE songFts MATCH ? ORDER BY bm25(songFts) LIMIT ?",
                arguments: [match, limit]
            )
        }

        if results.artists.count < limit {
            let more = try Artist.fetchAll(
                db,
                sql: "SELECT * FROM artist WHERE name LIKE ? ESCAPE '\\' ORDER BY name COLLATE NOCASE LIMIT ?",
                arguments: [like, limit]
            )
            let have = Set(results.artists.map(\.id))
            results.artists += more.filter { !have.contains($0.id) }.prefix(limit - results.artists.count)
        }
        if results.albums.count < limit {
            let more = try Album.fetchAll(
                db,
                sql: "SELECT * FROM album WHERE name LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' ORDER BY name COLLATE NOCASE LIMIT ?",
                arguments: [like, like, limit]
            )
            let have = Set(results.albums.map(\.id))
            results.albums += more.filter { !have.contains($0.id) }.prefix(limit - results.albums.count)
        }
        if results.songs.count < limit {
            let more = try Song.fetchAll(
                db,
                sql: "SELECT * FROM song WHERE title LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' OR album LIKE ? ESCAPE '\\' ORDER BY title COLLATE NOCASE LIMIT ?",
                arguments: [like, like, like, limit]
            )
            let have = Set(results.songs.map(\.id))
            results.songs += more.filter { !have.contains($0.id) }.prefix(limit - results.songs.count)
        }
        return results
    }
}
