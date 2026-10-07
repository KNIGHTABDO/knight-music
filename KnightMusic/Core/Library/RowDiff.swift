import Foundation
import GRDB

// MARK: - Tolerant comparison helpers

/// Dates round-trip through SQLite with millisecond precision; compare with that tolerance.
func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return abs(a.timeIntervalSince(b)) < 0.01
    default: return false
    }
}

/// Small tolerance comparison for ReplayGain gain and peak values.
func sameDouble(_ a: Double?, _ b: Double?, tolerance: Double = 0.0001) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return abs(a - b) < tolerance
    default: return false
    }
}

func sameReplayGain(_ a: ReplayGain?, _ b: ReplayGain?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?):
        return sameDouble(a.trackGain, b.trackGain)
            && sameDouble(a.albumGain, b.albumGain)
            && sameDouble(a.trackPeak, b.trackPeak)
            && sameDouble(a.albumPeak, b.albumPeak)
    default: return false
    }
}

// MARK: - Model equality

func sameArtist(_ a: Artist, _ b: Artist) -> Bool {
    a.id == b.id
        && a.name == b.name
        && a.coverArt == b.coverArt
        && a.artistImageUrl == b.artistImageUrl
        && a.albumCount == b.albumCount
        && sameInstant(a.starred, b.starred)
        && a.sortName == b.sortName
}

func sameAlbum(_ a: Album, _ b: Album) -> Bool {
    a.id == b.id
        && a.name == b.name
        && a.artist == b.artist
        && a.artistId == b.artistId
        && a.coverArt == b.coverArt
        && a.songCount == b.songCount
        && a.duration == b.duration
        && a.playCount == b.playCount
        && sameInstant(a.played, b.played)
        && sameInstant(a.created, b.created)
        && sameInstant(a.starred, b.starred)
        && a.year == b.year
        && a.genre == b.genre
        && a.userRating == b.userRating
        && a.sortName == b.sortName
        && a.isCompilation == b.isCompilation
}

func sameSong(_ a: Song, _ b: Song) -> Bool {
    a.id == b.id
        && a.title == b.title
        && a.album == b.album
        && a.albumId == b.albumId
        && a.artist == b.artist
        && a.artistId == b.artistId
        && a.track == b.track
        && a.discNumber == b.discNumber
        && a.year == b.year
        && a.genre == b.genre
        && a.coverArt == b.coverArt
        && a.size == b.size
        && a.contentType == b.contentType
        && a.suffix == b.suffix
        && a.duration == b.duration
        && a.bitRate == b.bitRate
        && a.samplingRate == b.samplingRate
        && a.path == b.path
        && a.playCount == b.playCount
        && sameInstant(a.played, b.played)
        && sameInstant(a.created, b.created)
        && sameInstant(a.starred, b.starred)
        && a.userRating == b.userRating
        && a.bpm == b.bpm
        && a.comment == b.comment
        && a.sortName == b.sortName
        && a.displayComposer == b.displayComposer
        && sameReplayGain(a.replayGain, b.replayGain)
}

func samePlaylist(_ a: Playlist, _ b: Playlist) -> Bool {
    a.id == b.id
        && a.name == b.name
        && a.comment == b.comment
        && a.owner == b.owner
        && a.public == b.public
        && a.songCount == b.songCount
        && a.duration == b.duration
        && sameInstant(a.created, b.created)
        && sameInstant(a.changed, b.changed)
        && a.coverArt == b.coverArt
}

func sameGenre(_ a: Genre, _ b: Genre) -> Bool {
    a.value == b.value
        && a.songCount == b.songCount
        && a.albumCount == b.albumCount
}

func sameRadioStation(_ a: RadioStation, _ b: RadioStation) -> Bool {
    a.id == b.id
        && a.name == b.name
        && a.streamUrl == b.streamUrl
        && a.homePageUrl == b.homePageUrl
}

// MARK: - Album content diffing

/// An album is "content-changed" if it is new or its songCount, duration, created, name, artist, coverArt, or year differ.
/// Ignores played, playCount, starred, userRating.
func isAlbumContentChanged(new: Album, old: Album?) -> Bool {
    guard let old else { return true }
    return old.songCount != new.songCount
        || old.duration != new.duration
        || !sameInstant(old.created, new.created)
        || old.name != new.name
        || old.artist != new.artist
        || old.coverArt != new.coverArt
        || old.year != new.year
}

// MARK: - Generic diff-based write

/// Writes only rows that are new or differ from their stored state according to `same`.
/// Skips unchanged rows so no FTS triggers or LiveQuery observations fire needlessly.
/// Returns the number of inserted and updated rows.
@discardableResult
func writeChanged<R: FetchableRecord & PersistableRecord & Identifiable>(
    _ rows: [R],
    in db: Database,
    same: (R, R) -> Bool
) throws -> Int where R.ID == String {
    guard !rows.isEmpty else { return 0 }
    let existing = try R.fetchAll(db, keys: rows.map(\.id))
    var existingById = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var written = 0
    for row in rows {
        if let old = existingById[row.id] {
            if !same(old, row) {
                try row.update(db)
                existingById[row.id] = row
                written += 1
            }
        } else {
            try row.insert(db)
            existingById[row.id] = row
            written += 1
        }
    }
    return written
}

// MARK: - Fast sweep temp table helper

/// Populates a temporary table `keep_ids` with the given IDs using a reused prepared statement.
func populateKeepIds(_ db: Database, keeping: Set<String>) throws {
    try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS keep_ids(id TEXT PRIMARY KEY)")
    try db.execute(sql: "DELETE FROM keep_ids")
    let stmt = try db.makeStatement(sql: "INSERT OR IGNORE INTO keep_ids(id) VALUES (?)")
    for id in keeping {
        try stmt.execute(arguments: [id])
    }
}
