import Foundation
import GRDB

/// Home shelves computed from the local mirror (play counts, play dates, favourites), so they work offline.
extension LibraryRepository {
    func recentlyPlayedSongs(limit: Int = 40) -> LiveQuery<[Song]> {
        query("recentlyPlayedSongs:\(limit)", initial: [Song]()) { db in
            try LibraryQueries.recentlyPlayedSongs(db, limit: limit)
        }
    }

    func topPicks() -> LiveQuery<[Album]> {
        let day = LibraryQueries.dayNumber()
        return query("topPicks:\(day)", initial: [Album]()) { db in try LibraryQueries.topPicks(db, day: day) }
    }

    func listenAgain() -> LiveQuery<[Album]> {
        query("listenAgain", initial: [Album]()) { db in try LibraryQueries.listenAgain(db) }
    }

    func rediscover(limit: Int? = 30) -> LiveQuery<[Album]> {
        let day = LibraryQueries.dayNumber()
        return query("rediscover:\(day):\(limit ?? 0)", initial: [Album]()) { db in
            try LibraryQueries.rediscover(db, day: day, limit: limit)
        }
    }

    func onThisDay() -> LiveQuery<[Album]> {
        let key = LibraryQueries.monthDay(Date())
        return query("onThisDay:\(key)", initial: [Album]()) { db in try LibraryQueries.onThisDay(db, monthDay: key) }
    }

    func recentlyAddedArtists(limit: Int = 20) -> LiveQuery<[Artist]> {
        query("recentlyAddedArtists:\(limit)", initial: [Artist]()) { db in
            try LibraryQueries.recentlyAddedArtists(db, limit: limit)
        }
    }

    func topGenres(limit: Int = 3) -> LiveQuery<[Genre]> {
        query("topGenres:\(limit)", initial: [Genre]()) { db in try LibraryQueries.topGenres(db, limit: limit) }
    }

    func genreShelf(_ genre: String) -> LiveQuery<[Album]> {
        query("genreShelf:\(genre)", initial: [Album]()) { db in
            try Array(LibraryQueries.albums(db, genre: genre).prefix(20))
        }
    }
}

extension LibraryQueries {
    /// Days since 1970 in the user's time zone: shelves reshuffle once a day, not on every render.
    static func dayNumber(_ date: Date = Date()) -> Int {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        return Int((date.timeIntervalSince1970 + Double(offset)) / 86_400)
    }

    static func monthDay(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 1, parts.day ?? 1)
    }

    /// Stable per-day order without SQLite's random(): FNV-1a of id + day.
    static func dailyOrder<T>(_ items: [T], day: Int, id: (T) -> String) -> [T] {
        func hash(_ s: String) -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in "\(s)#\(day)".utf8 {
                h ^= UInt64(byte)
                h = h &* 0x0000_0100_0000_01b3
            }
            return h
        }
        return items.map { (hash(id($0)), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func recentlyPlayedSongs(_ db: Database, limit: Int) throws -> [Song] {
        try Song.fetchAll(
            db,
            sql: "SELECT * FROM song WHERE played IS NOT NULL ORDER BY played DESC LIMIT ?",
            arguments: [limit]
        )
    }

    /// One album per most-played artist that hasn't been played in two weeks, favourites first.
    static func topPicks(_ db: Database, day: Int) throws -> [Album] {
        let candidates = try Album.fetchAll(
            db,
            sql: """
            WITH artistPlays AS (
                SELECT artistId, SUM(COALESCE(playCount, 0)) AS plays FROM album
                WHERE artistId IS NOT NULL GROUP BY artistId
                ORDER BY plays DESC LIMIT 24
            ), ranked AS (
                SELECT album.*, ROW_NUMBER() OVER (
                    PARTITION BY album.artistId
                    ORDER BY (album.starred IS NULL), COALESCE(album.playCount, 0) DESC
                ) AS pick
                FROM album JOIN artistPlays ON artistPlays.artistId = album.artistId
                WHERE album.played IS NULL OR album.played < datetime('now', '-14 days')
            )
            SELECT * FROM ranked WHERE pick = 1
            """
        )
        return Array(dailyOrder(candidates, day: day, id: \.id).prefix(8))
    }

    /// Albums from the last two months, most played first.
    static func listenAgain(_ db: Database) throws -> [Album] {
        try Album.fetchAll(
            db,
            sql: """
            SELECT * FROM album WHERE played >= datetime('now', '-60 days')
            ORDER BY COALESCE(playCount, 0) DESC, played DESC LIMIT 30
            """
        )
    }

    /// Favourite albums not played for six months (or never).
    static func rediscover(_ db: Database, day: Int, limit: Int?) throws -> [Album] {
        let candidates = try Album.fetchAll(
            db,
            sql: """
            SELECT * FROM album WHERE starred IS NOT NULL
            AND (played IS NULL OR played < datetime('now', '-6 months'))
            """
        )
        let ordered = dailyOrder(candidates, day: day, id: \.id)
        return limit.map { Array(ordered.prefix($0)) } ?? ordered
    }

    /// Albums played or added on this calendar day in an earlier year.
    static func onThisDay(_ db: Database, monthDay: String) throws -> [Album] {
        try Album.fetchAll(
            db,
            sql: """
            SELECT DISTINCT album.* FROM playEvent
            JOIN song ON song.id = playEvent.songId
            JOIN album ON album.id = song.albumId
            WHERE strftime('%m-%d', playEvent.playedAt, 'localtime') = ?
            AND strftime('%Y', playEvent.playedAt, 'localtime') < strftime('%Y', 'now', 'localtime')
            UNION
            SELECT * FROM album
            WHERE strftime('%m-%d', created, 'localtime') = ?
            AND strftime('%Y', created, 'localtime') < strftime('%Y', 'now', 'localtime')
            LIMIT 30
            """,
            arguments: [monthDay, monthDay]
        )
    }

    static func recentlyAddedArtists(_ db: Database, limit: Int) throws -> [Artist] {
        try Artist.fetchAll(
            db,
            sql: """
            SELECT artist.* FROM artist
            JOIN (SELECT artistId, MAX(created) AS added FROM album WHERE artistId IS NOT NULL GROUP BY artistId) latest
            ON latest.artistId = artist.id
            ORDER BY latest.added DESC LIMIT ?
            """,
            arguments: [limit]
        )
    }

    /// Genres the user plays most (falls back to the biggest ones before anything is played).
    static func topGenres(_ db: Database, limit: Int) throws -> [Genre] {
        try Genre.fetchAll(
            db,
            sql: """
            SELECT genre.* FROM genre
            LEFT JOIN (SELECT genre AS g, SUM(COALESCE(playCount, 0)) AS plays FROM album GROUP BY genre) p
            ON p.g = genre.value
            WHERE COALESCE(genre.albumCount, 0) >= 3
            ORDER BY COALESCE(p.plays, 0) DESC, genre.albumCount DESC LIMIT ?
            """,
            arguments: [limit]
        )
    }
}
