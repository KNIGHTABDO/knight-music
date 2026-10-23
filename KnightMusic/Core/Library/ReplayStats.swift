import Foundation
import GRDB

/// The time window a Knight Replay page covers. `offset` steps back from the current month/year (0 = now).
struct ReplayPeriod: Hashable, Sendable {
    enum Scope: String, Hashable, Sendable, CaseIterable, Identifiable {
        case month, year, allTime
        var id: String { rawValue }

        var title: String {
            switch self {
            case .month: "Month"
            case .year: "Year"
            case .allTime: "All Time"
            }
        }
    }

    var scope: Scope
    var offset: Int = 0

    /// `[start, end)` in the user's calendar; nil for all time.
    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        let component: Calendar.Component
        switch scope {
        case .month: component = .month
        case .year: component = .year
        case .allTime: return nil
        }
        guard let current = calendar.dateInterval(of: component, for: now),
              let start = calendar.date(byAdding: component, value: offset, to: current.start),
              let end = calendar.date(byAdding: component, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    var title: String {
        guard let interval = interval() else { return "All Time" }
        return scope == .month
            ? interval.start.formatted(.dateTime.month(.wide).year())
            : interval.start.formatted(.dateTime.year())
    }

    var canGoForward: Bool { scope != .allTime && offset < 0 }
}

struct ReplayStats: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Counted from plays recorded on this device (`playEvent`).
        case device
        /// Lifetime play counts reported by the server.
        case server
    }

    struct RankedSong: Equatable, Sendable, Identifiable, CoverArtProviding {
        var song: Song
        var plays: Int
        var id: String { song.id }
        var coverArtId: String? { song.coverArt }
    }

    struct RankedAlbum: Equatable, Sendable, Identifiable, CoverArtProviding {
        var album: Album
        var plays: Int
        var id: String { album.id }
        var coverArtId: String? { album.coverArt }
    }

    struct RankedArtist: Equatable, Sendable, Identifiable, CoverArtProviding {
        var artistId: String?
        var name: String
        var coverArt: String?
        var plays: Int
        var id: String { artistId ?? "name:\(name)" }
        var coverArtId: String? { coverArt }
    }

    struct RankedGenre: Equatable, Sendable, Identifiable {
        var name: String
        var plays: Int
        var id: String { name }
    }

    struct Bucket: Equatable, Sendable, Identifiable {
        var date: Date
        var plays: Int
        var id: Date { date }
    }

    var source: Source = .device
    var plays = 0
    var seconds = 0
    var songCount = 0
    var artistCount = 0
    var topSongs: [RankedSong] = []
    var topAlbums: [RankedAlbum] = []
    var topArtists: [RankedArtist] = []
    var topGenres: [RankedGenre] = []
    var activity: [Bucket] = []

    var isEmpty: Bool { plays == 0 }
    var minutes: Int { seconds / 60 }
}

extension LibraryRepository {
    func replay(_ period: ReplayPeriod) -> LiveQuery<ReplayStats> {
        let interval = period.interval()
        let key = "replay:\(period.scope.rawValue):\(interval.map { Int($0.start.timeIntervalSince1970) } ?? 0)"
        return query(key, initial: ReplayStats()) { db in
            try LibraryQueries.replay(db, scope: period.scope, interval: interval)
        }
    }
}

extension LibraryQueries {
    static func replay(_ db: Database, scope: ReplayPeriod.Scope, interval: DateInterval?) throws -> ReplayStats {
        if let interval {
            return try deviceReplay(db, scope: scope, interval: interval)
        }
        // All time: the server's lifetime counts cover listening from every client, not just this device.
        let server = try serverReplay(db)
        return server.isEmpty ? try deviceReplay(db, scope: .allTime, interval: nil) : server
    }

    private static func deviceReplay(_ db: Database, scope: ReplayPeriod.Scope, interval: DateInterval?) throws -> ReplayStats {
        let filter = interval == nil ? "1" : "playEvent.playedAt >= ? AND playEvent.playedAt < ?"
        var args = StatementArguments()
        if let interval { args = [interval.start, interval.end] }
        let from = "FROM playEvent JOIN song ON song.id = playEvent.songId WHERE \(filter)"

        var stats = ReplayStats(source: .device)
        if let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS plays, COALESCE(SUM(song.duration), 0) AS seconds,
                   COUNT(DISTINCT song.id) AS songs,
                   COUNT(DISTINCT COALESCE(song.artistId, song.artist)) AS artists
            \(from)
            """, arguments: args) {
            stats.plays = row["plays"] ?? 0
            stats.seconds = row["seconds"] ?? 0
            stats.songCount = row["songs"] ?? 0
            stats.artistCount = row["artists"] ?? 0
        }
        guard stats.plays > 0 else { return stats }

        stats.topSongs = try Row.fetchAll(db, sql: """
            SELECT song.*, COUNT(*) AS plays \(from)
            GROUP BY song.id ORDER BY plays DESC, MAX(playEvent.playedAt) DESC LIMIT 25
            """, arguments: args).map { ReplayStats.RankedSong(song: try Song(row: $0), plays: $0["plays"] ?? 0) }

        stats.topAlbums = try Row.fetchAll(db, sql: """
            SELECT album.*, COUNT(*) AS plays
            FROM playEvent JOIN song ON song.id = playEvent.songId JOIN album ON album.id = song.albumId
            WHERE \(filter)
            GROUP BY album.id ORDER BY plays DESC, MAX(playEvent.playedAt) DESC LIMIT 20
            """, arguments: args).map { ReplayStats.RankedAlbum(album: try Album(row: $0), plays: $0["plays"] ?? 0) }

        stats.topArtists = try Row.fetchAll(db, sql: """
            SELECT song.artistId AS artistId, MAX(song.artist) AS name, MAX(artist.coverArt) AS coverArt, COUNT(*) AS plays
            FROM playEvent JOIN song ON song.id = playEvent.songId LEFT JOIN artist ON artist.id = song.artistId
            WHERE \(filter) AND song.artist IS NOT NULL AND song.artist <> ''
            GROUP BY COALESCE(song.artistId, song.artist) ORDER BY plays DESC LIMIT 20
            """, arguments: args).map(rankedArtist)

        stats.topGenres = try Row.fetchAll(db, sql: """
            SELECT song.genre AS name, COUNT(*) AS plays \(from) AND song.genre IS NOT NULL AND song.genre <> ''
            GROUP BY song.genre ORDER BY plays DESC LIMIT 6
            """, arguments: args).map { ReplayStats.RankedGenre(name: $0["name"] ?? "", plays: $0["plays"] ?? 0) }

        stats.activity = try activity(db, scope: scope, interval: interval, filter: filter, args: args)
        return stats
    }

    private static func serverReplay(_ db: Database) throws -> ReplayStats {
        var stats = ReplayStats(source: .server)
        if let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(playCount), 0) AS plays,
                   COALESCE(SUM(playCount * COALESCE(duration, 0)), 0) AS seconds,
                   COUNT(*) AS songs,
                   COUNT(DISTINCT COALESCE(artistId, artist)) AS artists
            FROM song WHERE playCount > 0
            """) {
            stats.plays = row["plays"] ?? 0
            stats.seconds = row["seconds"] ?? 0
            stats.songCount = row["songs"] ?? 0
            stats.artistCount = row["artists"] ?? 0
        }
        guard stats.plays > 0 else { return stats }

        stats.topSongs = try Song.fetchAll(db, sql: "SELECT * FROM song WHERE playCount > 0 ORDER BY playCount DESC, played DESC LIMIT 25")
            .map { ReplayStats.RankedSong(song: $0, plays: $0.playCount ?? 0) }
        stats.topAlbums = try Album.fetchAll(db, sql: "SELECT * FROM album WHERE playCount > 0 ORDER BY playCount DESC, played DESC LIMIT 20")
            .map { ReplayStats.RankedAlbum(album: $0, plays: $0.playCount ?? 0) }
        stats.topArtists = try Row.fetchAll(db, sql: """
            SELECT song.artistId AS artistId, MAX(song.artist) AS name, MAX(artist.coverArt) AS coverArt, SUM(song.playCount) AS plays
            FROM song LEFT JOIN artist ON artist.id = song.artistId
            WHERE song.playCount > 0 AND song.artist IS NOT NULL AND song.artist <> ''
            GROUP BY COALESCE(song.artistId, song.artist) ORDER BY plays DESC LIMIT 20
            """).map(rankedArtist)
        stats.topGenres = try Row.fetchAll(db, sql: """
            SELECT genre AS name, SUM(playCount) AS plays FROM song
            WHERE playCount > 0 AND genre IS NOT NULL AND genre <> ''
            GROUP BY genre ORDER BY plays DESC LIMIT 6
            """).map { ReplayStats.RankedGenre(name: $0["name"] ?? "", plays: $0["plays"] ?? 0) }
        // Lifetime counts carry no dates; the chart shows what this device recorded, by year.
        stats.activity = try activity(db, scope: .allTime, interval: nil, filter: "1", args: [])
        return stats
    }

    private static func rankedArtist(_ row: Row) -> ReplayStats.RankedArtist {
        ReplayStats.RankedArtist(artistId: row["artistId"], name: row["name"] ?? "", coverArt: row["coverArt"], plays: row["plays"] ?? 0)
    }

    /// Plays per day (month view), per month (year view) or per year (all time), with empty buckets filled in.
    private static func activity(
        _ db: Database, scope: ReplayPeriod.Scope, interval: DateInterval?, filter: String, args: StatementArguments
    ) throws -> [ReplayStats.Bucket] {
        let (pattern, component): (String, Calendar.Component) = switch scope {
        case .month: ("%Y-%m-%d", .day)
        case .year: ("%Y-%m", .month)
        case .allTime: ("%Y", .year)
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT strftime('\(pattern)', playEvent.playedAt, 'localtime') AS bucket, COUNT(*) AS plays
            FROM playEvent WHERE \(filter) GROUP BY bucket
            """, arguments: args)
        var counts: [String: Int] = [:]
        for row in rows {
            if let bucket: String = row["bucket"] { counts[bucket] = row["plays"] ?? 0 }
        }
        guard !counts.isEmpty else { return [] }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = switch scope {
        case .month: "yyyy-MM-dd"
        case .year: "yyyy-MM"
        case .allTime: "yyyy"
        }

        let start: Date
        let end: Date
        if let interval {
            start = interval.start
            end = min(interval.end, calendar.date(byAdding: component, value: 1, to: Date()) ?? interval.end)
        } else {
            let first = counts.keys.sorted().first.flatMap(formatter.date(from:)) ?? Date()
            start = calendar.dateInterval(of: .year, for: first)?.start ?? first
            end = calendar.date(byAdding: .year, value: 1, to: calendar.dateInterval(of: .year, for: Date())?.start ?? Date()) ?? Date()
        }

        var buckets: [ReplayStats.Bucket] = []
        var cursor = start
        while cursor < end, buckets.count < 400 {
            buckets.append(ReplayStats.Bucket(date: cursor, plays: counts[formatter.string(from: cursor)] ?? 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return buckets
    }
}
