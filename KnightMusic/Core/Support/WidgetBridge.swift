import Foundation
import UIKit
import WidgetKit
import os

/// Bridges in-app playback state and library shelves to WidgetKit via an App Group container snapshot.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    private weak var app: AppModel?
    private var lastWrittenSnapshot: WidgetSnapshot?
    private var updateTask: Task<Void, Never>?
    private var recentQuery: LiveQuery<[Album]>?
    private var newestQuery: LiveQuery<[Album]>?
    private var favoritesQuery: LiveQuery<[Song]>?
    private var queryTasks: [Task<Void, Never>] = []
    private var loggedMissingAppGroup = false
    private let log = Logger(subsystem: "com.knightabdo.knightmusic", category: "widgetbridge")

    private init() {}

    func start(app: AppModel) {
        self.app = app
        IntentPlaybackBridge.handler = AppPlaybackHandler(app: app)
        IntentRecognitionBridge.handler = AppRecognitionHandler(app: app)

        observePlayer()
        setupLibraryQueries()

        app.addSessionObserver(fireImmediately: false) { [weak self] model in
            self?.setupLibraryQueries()
            if model.session == .loggedOut {
                self?.clearForLogout()
                return
            }
            self?.scheduleUpdate()
        }

        scheduleUpdate()
    }

    // MARK: - Observation

    private func observePlayer() {
        guard let player = app?.player else { return }
        withObservationTracking {
            _ = player.currentSong
            _ = player.isPlaying
            _ = player.duration
        } onChange: {
            Task { @MainActor [weak self] in
                self?.scheduleUpdate()
                self?.observePlayer()
            }
        }
    }

    private func setupLibraryQueries() {
        for task in queryTasks { task.cancel() }
        queryTasks.removeAll()

        guard let library = app?.library, app?.database != nil else {
            recentQuery = nil
            newestQuery = nil
            favoritesQuery = nil
            return
        }
        let recent = library.homeList(.recent)
        let newest = library.homeList(.newest)
        let favorites = library.favoriteSongs()
        recentQuery = recent
        newestQuery = newest
        favoritesQuery = favorites

        queryTasks.append(Task { await recent.run() })
        queryTasks.append(Task { await newest.run() })
        queryTasks.append(Task { await favorites.run() })

        observeLibrary()
    }

    private func observeLibrary() {
        guard let recent = recentQuery, let newest = newestQuery else { return }
        let favorites = favoritesQuery
        withObservationTracking {
            _ = recent.value
            _ = newest.value
            _ = favorites?.value
        } onChange: {
            Task { @MainActor [weak self] in
                self?.scheduleUpdate()
                self?.observeLibrary()
            }
        }
    }

    // MARK: - Debounced Updates

    func scheduleUpdate() {
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performUpdate()
        }
    }

    private func performUpdate() async {
        guard let containerURL = WidgetSnapshot.containerURL else {
            if !loggedMissingAppGroup {
                loggedMissingAppGroup = true
                Log.app.warning("App Group \(WidgetSnapshot.appGroupID) container not available; widget updates skipped.")
            }
            return
        }

        guard let app else { return }
        let player = app.player

        let artworkDir = containerURL.appendingPathComponent(WidgetSnapshot.artworkDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)

        // 1. Now Playing
        var nowPlayingSnapshot: WidgetNowPlaying?
        var referencedFiles = Set<String>()

        if let song = player.currentSong {
            var artworkFilename: String?
            var dominantHex: String?

            if let coverArt = song.coverArt ?? song.albumId {
                artworkFilename = await saveArtwork(coverArt: coverArt, prefix: "cover", in: artworkDir)
                if let artworkFilename { referencedFiles.insert(artworkFilename) }

                let palette = await ArtworkPalette.palette(for: coverArt)
                if let firstColor = palette.colors.first {
                    dominantHex = hexString(for: firstColor)
                }
            }

            nowPlayingSnapshot = WidgetNowPlaying(
                title: song.title,
                artist: song.artist ?? "",
                album: song.album ?? "",
                albumId: song.albumId,
                isPlaying: player.isPlaying,
                duration: player.duration,
                elapsed: player.elapsedNow(),
                timestamp: Date(),
                artworkFilename: artworkFilename,
                dominantColorHex: dominantHex
            )
        }

        // 2. Recent and Newest Albums
        let recentAlbums = await fetchRecentAlbums()
        let newestAlbums = await fetchNewestAlbums()

        var widgetRecent: [WidgetAlbum] = []
        for album in recentAlbums {
            var artworkFilename: String?
            if let coverArt = album.coverArt ?? Optional(album.id) {
                artworkFilename = await saveArtwork(coverArt: coverArt, prefix: "album", in: artworkDir)
                if let artworkFilename { referencedFiles.insert(artworkFilename) }
            }
            widgetRecent.append(WidgetAlbum(id: album.id, name: album.name, artist: album.artist, artworkFilename: artworkFilename))
        }

        var widgetNewest: [WidgetAlbum] = []
        for album in newestAlbums {
            var artworkFilename: String?
            if let coverArt = album.coverArt ?? Optional(album.id) {
                artworkFilename = await saveArtwork(coverArt: coverArt, prefix: "album", in: artworkDir)
                if let artworkFilename { referencedFiles.insert(artworkFilename) }
            }
            widgetNewest.append(WidgetAlbum(id: album.id, name: album.name, artist: album.artist, artworkFilename: artworkFilename))
        }

        // 3. Favourite songs (newest first, as the Favorites list shows them)
        let favoriteSongs = favoritesQuery?.value ?? []
        var widgetFavorites: [WidgetSong] = []
        for song in favoriteSongs.prefix(8) {
            var artworkFilename: String?
            if let coverArt = song.coverArt ?? song.albumId {
                artworkFilename = await saveArtwork(coverArt: coverArt, prefix: "album", in: artworkDir)
                if let artworkFilename { referencedFiles.insert(artworkFilename) }
            }
            widgetFavorites.append(WidgetSong(id: song.id, title: song.title, artist: song.artist, artworkFilename: artworkFilename))
        }

        // 4. Build snapshot & skip if content is identical
        let newSnapshot = WidgetSnapshot(
            nowPlaying: nowPlayingSnapshot,
            recentAlbums: widgetRecent,
            newestAlbums: widgetNewest,
            favorites: widgetFavorites,
            favoriteCount: favoriteSongs.count,
            updatedAt: Date()
        )

        if let last = lastWrittenSnapshot, newSnapshot.isContentEqual(to: last) {
            return
        }

        // 5. Write snapshot JSON and notify WidgetKit
        do {
            let snapshotURL = containerURL.appendingPathComponent(WidgetSnapshot.snapshotFileName)
            let data = try JSONEncoder().encode(newSnapshot)
            try data.write(to: snapshotURL, options: .atomic)
            lastWrittenSnapshot = newSnapshot
            // Only now drop artwork the new snapshot no longer references, so a render between the two never sees a missing file.
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: artworkDir.path) {
                for file in contents where !referencedFiles.contains(file) {
                    try? FileManager.default.removeItem(at: artworkDir.appendingPathComponent(file))
                }
            }
            WidgetCenter.shared.reloadAllTimelines()
            log.info("Widget snapshot written successfully; timelines reloaded.")
        } catch {
            log.error("Failed to write widget snapshot: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Downloads/decodes the cover and writes it as a JPEG in the App Group; encoding and IO run off the main actor.
    private func saveArtwork(coverArt: String, prefix: String, in dir: URL) async -> String? {
        let filename = "\(prefix)_\(safeFilename(for: coverArt)).jpg"
        let fileURL = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) { return filename }
        guard let image = await ArtworkLoader.shared.image(coverArt: coverArt, size: 300) else { return nil }
        let written = await Self.writeJPEG(image, to: fileURL)
        return written ? filename : nil
    }

    private nonisolated static func writeJPEG(_ image: UIImage, to url: URL) async -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.app.warning("Widget artwork write failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    /// Session ended: widgets must not keep showing the previous account's library.
    private func clearForLogout() {
        recentQuery = nil
        newestQuery = nil
        favoritesQuery = nil
        updateTask?.cancel()
        lastWrittenSnapshot = nil
        guard let containerURL = WidgetSnapshot.containerURL else { return }
        do {
            let data = try JSONEncoder().encode(WidgetSnapshot())
            try data.write(to: containerURL.appendingPathComponent(WidgetSnapshot.snapshotFileName), options: .atomic)
            let dir = containerURL.appendingPathComponent(WidgetSnapshot.artworkDirectoryName, isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for file in files { try? FileManager.default.removeItem(at: dir.appendingPathComponent(file)) }
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Log.app.error("Clearing the widget snapshot on logout failed: \(error)")
        }
    }

    private func fetchRecentAlbums() async -> [Album] {
        if let list = recentQuery?.value, !list.isEmpty {
            return Array(list.prefix(8))
        }
        guard let db = app?.database else { return [] }
        do {
            return try await db.pool.read { db in
                try LibraryQueries.albums(db, sort: .recentlyPlayed, search: "", limit: 8)
            }
        } catch {
            Log.app.warning("Widget fetchRecentAlbums failed: \(error)")
            return []
        }
    }

    private func fetchNewestAlbums() async -> [Album] {
        if let list = newestQuery?.value, !list.isEmpty {
            return Array(list.prefix(8))
        }
        guard let db = app?.database else { return [] }
        do {
            return try await db.pool.read { db in
                try LibraryQueries.albums(db, sort: .recentlyAdded, search: "", limit: 8)
            }
        } catch {
            Log.app.warning("Widget fetchNewestAlbums failed: \(error)")
            return []
        }
    }

    private func safeFilename(for id: String) -> String {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return safe.replacingOccurrences(of: "/", with: "_")
    }

    private func hexString(for color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
