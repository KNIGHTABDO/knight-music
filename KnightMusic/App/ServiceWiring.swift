import Foundation
import Observation
import UIKit

// MARK: - PlaybackURLProvider

extension SubsonicClient: PlaybackURLProvider {}

// MARK: - PlaybackServerActions

struct SubsonicServerActions: PlaybackServerActions {
    let client: SubsonicClient

    func scrobble(songId: String, time: Date, submission: Bool) async throws {
        try await client.scrobble(id: songId, time: time, submission: submission)
    }

    func savePlayQueue(songIds: [String], currentSongId: String?, positionMs: Int) async throws {
        try await client.savePlayQueue(ids: songIds, current: currentSongId, positionMs: positionMs)
    }

    func getPlayQueue() async throws -> ServerPlayQueue? {
        guard let q = try await client.getPlayQueue() else { return nil }
        return ServerPlayQueue(
            songs: q.songs,
            currentSongId: q.currentId,
            positionMs: q.positionMs,
            changed: q.changed,
            changedBy: q.changedBy
        )
    }

    func setStarred(songId: String, starred: Bool) async throws {
        if starred {
            try await client.star(id: songId)
        } else {
            try await client.unstar(id: songId)
        }
    }

    func similarSongs(to song: Song, count: Int) async throws -> [Song] {
        let direct = try await client.getSimilarSongs(id: song.id, count: count)
        if !direct.isEmpty { return direct }
        guard let artistId = song.artistId else { return [] }
        return try await client.getSimilarSongs2(id: artistId, count: count)
    }
}

// MARK: - ArtworkBridge

final class ArtworkBridge: ArtworkProviding, @unchecked Sendable {
    private let service: AnimatedArtworkService

    init(service: AnimatedArtworkService) {
        self.service = service
    }

    func image(coverArt: String?, size: Int) async -> UIImage? {
        await ArtworkLoader.shared.image(coverArt: coverArt, size: size)
    }

    func cachedImage(coverArt: String?, size: Int) -> UIImage? {
        ArtworkLoader.shared.cachedImage(coverArt: coverArt, size: size)
    }

    func nowPlayingEntries(for song: Song) async -> [String: Any] {
        await service.nowPlayingEntries(for: song)
    }
}

// MARK: - AppModel Extension

extension AppModel {
    func installServiceWiring() {
        playbackServices.artwork = ArtworkBridge(service: artwork)

        playbackServices.reresolveAddress = { [weak self] in
            await self?.reresolveAddress()
            return self?.client?.baseURL
        }
        playbackServices.currentBaseURL = { [weak self] in
            self?.client?.baseURL
        }
        playbackServices.networkChangeCount = { [weak self] in
            self?.network.changeCount ?? 0
        }
        playbackServices.isResolvingAddress = { [weak self] in
            self?.addressResolver.isResolving ?? false
        }
        playbackServices.waitForAddressResolution = { [weak self] timeout in
            await self?.waitForAddressResolution(timeout: timeout)
        }

        playbackServices.settingsProvider = { [weak self] in
            guard let self else { return PlaybackSettings() }
            let isCellular = self.network.isExpensive || self.network.isCellular
            let transcode = isCellular ? self.settings.cellularFormat : self.settings.wifiFormat
            let dlFormat = self.settings.downloadFormat

            var s = PlaybackSettings()
            s.wifiMaxBitRate = self.settings.wifiMaxBitRate
            s.cellularMaxBitRate = self.settings.cellularMaxBitRate
            s.transcodeFormat = (transcode.isEmpty || transcode == "raw") ? nil : transcode
            s.downloadMaxBitRate = self.settings.downloadMaxBitRate
            s.downloadFormat = (dlFormat.isEmpty || dlFormat == "raw") ? nil : dlFormat
            s.gapless = self.settings.gaplessEnabled
            s.autoMix = self.settings.autoMixEnabled
            s.replayGain = ReplayGainMode(rawValue: self.settings.replayGainMode.rawValue) ?? .off
            s.scrobblingEnabled = self.settings.scrobblingEnabled
            s.offlineMode = self.isOffline
            s.streamCacheLimitMB = self.settings.streamCacheLimitMB
            s.serverQueueSyncEnabled = self.settings.syncPlayQueueWithServer
            s.saveAheadMode = SaveAheadMode(rawValue: self.settings.saveAheadMode.rawValue) ?? .off
            s.crossfadeSeconds = self.settings.crossfadeSeconds
            s.playbackSpeed = Float(self.settings.playbackSpeed)
            s.eqEnabled = self.settings.eqEnabled
            s.eqGains = self.settings.eqGains.map { Float($0) }
            s.downloadOnCellular = self.settings.downloadOverCellular
            return s
        }

        playbackServices.networkProvider = { [weak self] in
            guard let self else { return .wifi }
            if !self.network.isConnected {
                return .offline
            }
            if self.network.isExpensive || self.network.isCellular {
                return .cellular
            }
            return .wifi
        }

        player.onStarChanged = { [weak self] songId, starred in
            Task { @MainActor [weak self] in
                await self?.library.applyLocalStar(songId: songId, starred: starred)
            }
        }

        library.onSongStarChanged = { [weak self] songId, starred in
            self?.player.songStarChanged(songId: songId, starred: starred)
        }

        addSessionObserver { app in
            ArtworkLoader.configure(provider: app.client)
            app.playbackServices.urls = app.client
            app.playbackServices.server = app.client.map(SubsonicServerActions.init)
            app.playbackServices.autoMix = app.client.map { client in
                AutoMixClient(urls: { path, items in client.autoMixURL(path: path, items: items) })
            }
            if let db = app.database {
                let dbId = ObjectIdentifier(db)
                if app.lastConfiguredDatabaseId != dbId {
                    app.lastConfiguredDatabaseId = dbId
                    app.downloads.configure(services: app.playbackServices, database: db.pool)
                    app.player.configure(services: app.playbackServices, downloads: app.downloads, database: db.pool)
                }
            } else {
                app.lastConfiguredDatabaseId = nil
            }
            app.player.servicesDidChange()
            app.updateAutoDownloads()
        }

        observeSettings()
    }

    func updateAutoDownloads() {
        autoDownloader.update(database: database, downloads: downloads,
                              favorites: settings.autoDownloadFavorites, playlistIds: settings.autoDownloadPlaylistIds)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.wifiMaxBitRate
            _ = settings.wifiFormat
            _ = settings.cellularMaxBitRate
            _ = settings.cellularFormat
            _ = settings.downloadMaxBitRate
            _ = settings.downloadFormat
            _ = settings.offlineMode
            _ = settings.manualOfflineEnabled
            _ = settings.streamCacheLimitMB
            _ = settings.gaplessEnabled
            _ = settings.autoMixEnabled
            _ = settings.replayGainMode
            _ = settings.scrobblingEnabled
            _ = settings.syncPlayQueueWithServer
            _ = settings.saveAheadMode
            _ = settings.crossfadeSeconds
            _ = settings.playbackSpeed
            _ = settings.eqEnabled
            _ = settings.eqGains
            _ = settings.downloadOverCellular
            _ = settings.autoDownloadFavorites
            _ = settings.autoDownloadPlaylistIds
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.settingsDidChange()
                self.downloads.networkDidChange()
                self.updateAutoDownloads()
                self.observeSettings()
            }
        }
    }
}
