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
    private var queryTasks: [Task<Void, Never>] = []
    private var loggedMissingAppGroup = false
    private let log = Logger(subsystem: "com.knightabdo.knightmusic", category: "widgetbridge")

    private init() {}

    func start(app: AppModel) {
        self.app = app
        IntentPlaybackBridge.handler = AppPlaybackHandler(app: app)

        observePlayer()
        setupLibraryQueries()

        app.addSessionObserver(fireImmediately: false) { [weak self] _ in
            self?.setupLibraryQueries()
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

        guard let library = app?.library, app?.database != nil else { return }
        let recent = library.homeList(.recent)
        let newest = library.homeList(.newest)
        recentQuery = recent
        newestQuery = newest

        queryTasks.append(Task { await recent.run() })
        queryTasks.append(Task { await newest.run() })

        observeLibrary()
    }

    private func observeLibrary() {
        guard let recent = recentQuery, let newest = newestQuery else { return }
        withObservationTracking {
            _ = recent.value
            _ = newest.value
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
                let filename = "cover_\(safeFilename(for: coverArt)).jpg"
                let fileURL = artworkDir.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    if let image = await ArtworkLoader.shared.image(coverArt: coverArt, size: 300),
                       let data = image.jpegData(compressionQuality: 0.85) {
                        try? data.write(to: fileURL, options: .atomic)
                    }
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    artworkFilename = filename
                    referencedFiles.insert(filename)
                }

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
                let filename = "album_\(safeFilename(for: coverArt)).jpg"
                let fileURL = artworkDir.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    if let image = await ArtworkLoader.shared.image(coverArt: coverArt, size: 300),
                       let data = image.jpegData(compressionQuality: 0.85) {
                        try? data.write(to: fileURL, options: .atomic)
                    }
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    artworkFilename = filename
                    referencedFiles.insert(filename)
                }
            }
            widgetRecent.append(WidgetAlbum(id: album.id, name: album.name, artist: album.artist, artworkFilename: artworkFilename))
        }

        var widgetNewest: [WidgetAlbum] = []
        for album in newestAlbums {
            var artworkFilename: String?
            if let coverArt = album.coverArt ?? Optional(album.id) {
                let filename = "album_\(safeFilename(for: coverArt)).jpg"
                let fileURL = artworkDir.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    if let image = await ArtworkLoader.shared.image(coverArt: coverArt, size: 300),
                       let data = image.jpegData(compressionQuality: 0.85) {
                        try? data.write(to: fileURL, options: .atomic)
                    }
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    artworkFilename = filename
                    referencedFiles.insert(filename)
                }
            }
            widgetNewest.append(WidgetAlbum(id: album.id, name: album.name, artist: album.artist, artworkFilename: artworkFilename))
        }

        // 3. Build snapshot & skip if content is identical
        let newSnapshot = WidgetSnapshot(
            nowPlaying: nowPlayingSnapshot,
            recentAlbums: widgetRecent,
            newestAlbums: widgetNewest,
            updatedAt: Date()
        )

        if let last = lastWrittenSnapshot, newSnapshot.isContentEqual(to: last) {
            return
        }

        // 4. Clean up unreferenced artwork files
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: artworkDir.path) {
            for file in contents where !referencedFiles.contains(file) {
                let url = artworkDir.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: url)
            }
        }

        // 5. Write snapshot JSON and notify WidgetKit
        do {
            let snapshotURL = containerURL.appendingPathComponent(WidgetSnapshot.snapshotFileName)
            let data = try JSONEncoder().encode(newSnapshot)
            try data.write(to: snapshotURL, options: .atomic)
            lastWrittenSnapshot = newSnapshot
            WidgetCenter.shared.reloadAllTimelines()
            log.info("Widget snapshot written successfully; timelines reloaded.")
        } catch {
            log.error("Failed to write widget snapshot: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func fetchRecentAlbums() async -> [Album] {
        if let list = recentQuery?.value, !list.isEmpty {
            return Array(list.prefix(8))
        }
        guard let db = app?.database else { return [] }
        return (try? await db.pool.read { db in
            try LibraryQueries.albums(db, sort: .recentlyPlayed, search: "", limit: 8)
        }) ?? []
    }

    private func fetchNewestAlbums() async -> [Album] {
        if let list = newestQuery?.value, !list.isEmpty {
            return Array(list.prefix(8))
        }
        guard let db = app?.database else { return [] }
        return (try? await db.pool.read { db in
            try LibraryQueries.albums(db, sort: .recentlyAdded, search: "", limit: 8)
        }) ?? []
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
