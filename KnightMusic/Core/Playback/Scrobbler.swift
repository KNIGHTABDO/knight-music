import Foundation
import GRDB

/// Now-playing + scrobble submission. Failed/offline submissions are parked in `pendingScrobble` and flushed later.
@MainActor
final class Scrobbler {
    private var services: PlaybackServices?
    private var database: DatabaseWriter?
    private var song: Song?
    private var startedAt = Date()
    private var played: TimeInterval = 0
    private var submitted = false
    private var isFlushing = false

    func configure(services: PlaybackServices, database: DatabaseWriter) {
        self.services = services
        self.database = database
        flushPending()
    }

    /// A song actually began playing.
    func begin(_ song: Song) {
        self.song = song
        startedAt = Date()
        played = 0
        submitted = false
        guard let services, services.settings.scrobblingEnabled, let server = services.server else { return }
        flushPending()
        guard !services.isOffline else { return }
        let id = song.id
        Task {
            do {
                try await server.scrobble(songId: id, time: Date(), submission: false)
            } catch {
                PlaybackLog.logger.error("Now-playing report failed: \(error.localizedDescription)")
            }
        }
    }

    func addPlayed(_ delta: TimeInterval) {
        guard let song, !submitted, let services, services.settings.scrobblingEnabled else { return }
        played += delta
        let total = song.durationSeconds
        let reachedHalf = total >= 30 && played >= total * 0.5
        if reachedHalf || played >= 240 { submit(song, at: startedAt) }
    }

    func end() {
        song = nil
    }

    func flushPending() {
        guard !isFlushing, let services, let database, let server = services.server,
              services.settings.scrobblingEnabled, !services.isOffline else { return }
        isFlushing = true
        Task {
            defer { isFlushing = false }
            while true {
                let rows: [PendingScrobbleRecord]
                do {
                    rows = try await database.read { try PendingScrobbleRecord.order(Column("id")).limit(50).fetchAll($0) }
                } catch {
                    PlaybackLog.logger.error("Pending scrobble read failed: \(error.localizedDescription)")
                    return
                }
                if rows.isEmpty { return }
                for row in rows {
                    do {
                        try await server.scrobble(songId: row.songId, time: row.time, submission: row.submission)
                    } catch {
                        PlaybackLog.logger.error("Pending scrobble flush failed: \(error.localizedDescription)")
                        return
                    }
                    if let id = row.id {
                        do {
                            try await database.write { _ = try PendingScrobbleRecord.deleteOne($0, key: id) }
                        } catch {
                            PlaybackLog.logger.error("Pending scrobble delete failed: \(error.localizedDescription)")
                            return
                        }
                    }
                }
            }
        }
    }

    private func submit(_ song: Song, at time: Date) {
        submitted = true
        guard let services, let server = services.server else { return }
        let id = song.id
        if services.isOffline {
            store(songId: id, time: time)
            return
        }
        Task {
            do {
                try await server.scrobble(songId: id, time: time, submission: true)
                flushPending()
            } catch {
                PlaybackLog.logger.error("Scrobble failed, queued: \(error.localizedDescription)")
                store(songId: id, time: time)
            }
        }
    }

    private func store(songId: String, time: Date) {
        guard let database else { return }
        Task {
            do {
                try await database.write { db in
                    var record = PendingScrobbleRecord(id: nil, songId: songId, time: time, submission: true)
                    try record.insert(db)
                }
            } catch {
                PlaybackLog.logger.error("Storing pending scrobble failed: \(error.localizedDescription)")
            }
        }
    }
}
