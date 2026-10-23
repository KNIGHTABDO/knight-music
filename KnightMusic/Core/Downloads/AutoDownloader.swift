import Foundation
import GRDB

/// Keeps favourite songs and chosen playlists downloaded: watches them in the mirror and queues whatever is new.
/// Songs that leave a list stay downloaded (removing downloads is always the user's call).
@MainActor
final class AutoDownloader {
    private var task: Task<Void, Never>?
    private var signature = ""

    func update(database: LibraryDatabase?, downloads: DownloadManager, favorites: Bool, playlistIds: [String]) {
        let ids = playlistIds.sorted()
        let next = database.map { "\(ObjectIdentifier($0))|\(favorites)|\(ids.joined(separator: ","))" } ?? ""
        guard next != signature else { return }
        signature = next
        task?.cancel()
        task = nil
        guard let database, favorites || !ids.isEmpty else { return }

        let observation = ValueObservation.tracking { db -> [Song] in
            var songs = favorites ? try LibraryQueries.favoriteSongs(db) : []
            for id in ids { songs += try LibraryQueries.playlistSongs(db, id: id) }
            return songs
        }
        task = Task { [weak downloads] in
            do {
                for try await songs in observation.values(in: database.pool) {
                    guard let downloads else { return }
                    var seen = Set<String>()
                    let missing = songs.filter { downloads.status(for: $0.id) == nil && seen.insert($0.id).inserted }
                    if !missing.isEmpty {
                        Log.downloads.info("Auto-download: queueing \(missing.count) songs")
                        downloads.download(songs: missing)
                    }
                }
            } catch is CancellationError {
            } catch {
                Log.downloads.error("Auto-download observation failed: \(error.localizedDescription)")
            }
        }
    }
}
