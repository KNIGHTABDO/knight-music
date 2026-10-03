import Foundation
import GRDB

struct AlbumStorage: Identifiable, Hashable {
    var albumId: String
    var albumName: String?
    var artist: String?
    var songCount: Int
    var bytes: Int
    var id: String { albumId }
}

/// Disk usage for downloads and the stream cache.
@MainActor @Observable
final class StorageManager {
    private(set) var downloadBytes = 0
    private(set) var cacheBytes = 0
    private(set) var downloadedSongCount = 0

    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let cache: StreamCache

    init(downloads: DownloadManager, cache: StreamCache) {
        self.downloads = downloads
        self.cache = cache
        refresh()
    }

    func refresh() {
        downloadBytes = downloads.completedBytes
        downloadedSongCount = downloads.completedCount
        cacheBytes = cache.totalBytes
    }

    func clearCache() {
        cache.clear()
        refresh()
    }

    /// Downloaded bytes grouped by album (largest first). Needs the library mirror's `song` table.
    func albumBreakdown() async -> [AlbumStorage] {
        guard let database = downloads.database else { return [] }
        do {
            return try await database.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT song.albumId AS albumId, MAX(song.album) AS album, MAX(song.artist) AS artist,
                           COUNT(*) AS songs, SUM(download.bytes) AS bytes
                    FROM download JOIN song ON song.id = download.songId
                    WHERE download.state = 'completed' AND song.albumId IS NOT NULL
                    GROUP BY song.albumId ORDER BY bytes DESC
                    """)
                return rows.compactMap { row -> AlbumStorage? in
                    guard let albumId: String = row["albumId"] else { return nil }
                    return AlbumStorage(albumId: albumId, albumName: row["album"], artist: row["artist"],
                                        songCount: row["songs"] ?? 0, bytes: row["bytes"] ?? 0)
                }
            }
        } catch {
            PlaybackLog.logger.error("Album storage breakdown failed: \(error.localizedDescription)")
            return []
        }
    }

    static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
