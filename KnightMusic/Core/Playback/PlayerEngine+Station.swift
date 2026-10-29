import Foundation
import GRDB

// Stations ("Instant Mix"): start from a song, then keep the queue topped up with songs similar to
// whatever is playing. Server agents first; the local mirror (same artist / genre) when they have nothing.
extension PlayerEngine {
    private static let stationBatch = 25
    private static let stationLowWater = 3

    func startStation(from song: Song) async {
        stationRefillTask?.cancel()
        stationRefillTask = nil
        play([song], startAt: 0, shuffle: false)
        stationSeed = song
        let picks = await stationSongs(after: song, excluding: [song.id])
        guard !Task.isCancelled, stationSeed?.id == song.id else { return }
        if picks.isEmpty {
            report("No similar songs found for \(song.title).")
        } else {
            enqueue(picks, next: false)
        }
    }

    func endStation() {
        stationSeed = nil
        stationRefillTask?.cancel()
        stationRefillTask = nil
    }

    func refillStationIfNeeded() {
        guard stationSeed != nil, stationRefillTask == nil, let current = currentSong,
              order.count - currentIndex - 1 < Self.stationLowWater else { return }
        stationRefillTask = Task { [weak self] in
            guard let self else { return }
            let known = Set(self.order.map(\.song.id))
            let picks = await self.stationSongs(after: current, excluding: known)
            self.stationRefillTask = nil
            guard !Task.isCancelled, self.stationSeed != nil, !picks.isEmpty else { return }
            self.enqueue(picks, next: false)
        }
    }

    private func stationSongs(after song: Song, excluding known: Set<String>) async -> [Song] {
        var picks: [Song] = []
        if let videoId = song.youTubeVideoId {
            guard !services.isInternetOffline else { return [] }
            do {
                picks = try await YouTubeMusic.shared.radio(videoId: videoId).map(\.song)
            } catch {
                PlaybackLog.logger.error("YouTube radio failed: \(error.localizedDescription, privacy: .public)")
            }
            var seen = Set<String>()
            return Array(picks.filter { !known.contains($0.id) && seen.insert($0.id).inserted }.prefix(Self.stationBatch))
        }
        if !services.isOffline, let server = services.server {
            do {
                picks = try await server.similarSongs(to: song, count: Self.stationBatch * 2)
            } catch {
                PlaybackLog.logger.error("Station similar songs failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        picks = picks.filter { !known.contains($0.id) && isPlayable($0) }
        if picks.count < Self.stationBatch / 2 {
            let local = await localStationSongs(like: song, excluding: known.union(picks.map(\.id)))
            picks += local
        }
        var seen = Set<String>()
        return Array(picks.filter { seen.insert($0.id).inserted }.prefix(Self.stationBatch))
    }

    /// Same artist and same genre, favourites and less-recently-played songs first, lightly shuffled.
    private func localStationSongs(like song: Song, excluding known: Set<String>) async -> [Song] {
        guard let database = stationDatabase else { return [] }
        let artistId = song.artistId ?? ""
        let genre = song.genre ?? ""
        do {
            let rows = try await database.read { db in
                try Song.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM song
                    WHERE (artistId = ? OR (genre = ? AND genre <> ''))
                    ORDER BY (starred IS NULL), COALESCE(played, '') ASC
                    LIMIT 300
                    """,
                    arguments: [artistId, genre]
                )
            }
            let fresh = rows.filter { !known.contains($0.id) && isPlayable($0) }
            let sameArtist = fresh.filter { $0.artistId == song.artistId }.shuffled().prefix(6)
            let sameGenre = fresh.filter { $0.artistId != song.artistId }.prefix(80).shuffled()
            return Array(sameArtist) + sameGenre
        } catch {
            PlaybackLog.logger.error("Station local query failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
