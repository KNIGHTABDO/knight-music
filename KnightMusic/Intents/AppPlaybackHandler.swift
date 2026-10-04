import Foundation
import GRDB

@MainActor
final class AppPlaybackHandler: IntentPlaybackHandling {
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    private var activeApp: AppModel? {
        app ?? AppModel.shared
    }

    func playPause() {
        guard let app = activeApp else { return }
        app.player.togglePlayPause()
    }

    func nextTrack() {
        guard let app = activeApp else { return }
        app.player.next()
    }

    func previousTrack() {
        guard let app = activeApp else { return }
        app.player.previous()
    }

    func shuffleLibrary() async {
        guard let app = activeApp, let db = app.database else { return }
        do {
            let songs = try await db.pool.read { db in
                try Song.fetchAll(db, sql: "SELECT * FROM song ORDER BY RANDOM() LIMIT 200")
            }
            guard !songs.isEmpty else { return }
            app.player.play(songs, startAt: 0, shuffle: false)
        } catch {
            Log.app.error("ShuffleLibrary intent failed: \(error.localizedDescription)")
        }
    }

    func playFavorites() async {
        guard let app = activeApp, let db = app.database else { return }
        do {
            let songs = try await db.pool.read { db in
                try LibraryQueries.favoriteSongs(db)
            }
            guard !songs.isEmpty else { return }
            app.player.play(songs, startAt: 0, shuffle: true)
        } catch {
            Log.app.error("PlayFavorites intent failed: \(error.localizedDescription)")
        }
    }
}
