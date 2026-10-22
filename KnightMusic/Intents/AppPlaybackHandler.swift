import Foundation
import GRDB

@MainActor
final class AppPlaybackHandler: IntentPlaybackHandling {
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    private var activeApp: AppModel? {
        if let app { return app }
        if let shared = AppModel.shared { return shared }
        let model = AppModel()
        AppModel.shared = model
        return model
    }

    private func waitForReady() async -> (AppModel, LibraryDatabase)? {
        guard let app = activeApp else { return nil }
        app.startIfNeeded()
        if app.session == .ready, let db = app.database {
            return (app, db)
        }
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if app.session == .ready, let db = app.database {
                return (app, db)
            }
            if case .loggedOut = app.session, app.accounts.active == nil {
                return nil
            }
        }
        if app.session == .ready, let db = app.database {
            return (app, db)
        }
        return nil
    }

    func playPause() {
        guard let app = activeApp else { return }
        app.startIfNeeded()
        app.player.togglePlayPause()
    }

    func nextTrack() {
        guard let app = activeApp else { return }
        app.startIfNeeded()
        app.player.next()
    }

    func previousTrack() {
        guard let app = activeApp else { return }
        app.startIfNeeded()
        app.player.previous()
    }

    func shuffleLibrary() async {
        guard let (app, db) = await waitForReady() else {
            Log.app.error("ShuffleLibrary intent failed: app not ready or not signed in")
            return
        }
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
        guard let (app, db) = await waitForReady() else {
            Log.app.error("PlayFavorites intent failed: app not ready or not signed in")
            return
        }
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
