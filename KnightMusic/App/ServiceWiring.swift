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

    func nowPlayingEntries(for song: Song) async -> [String: Any] {
        await service.nowPlayingEntries(for: song)
    }
}

// MARK: - AppModel Extension

extension AppModel {
    func installServiceWiring() {
        playbackServices.artwork = ArtworkBridge(service: artwork)

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
        }

        observeSettings()
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.settingsDidChange()
                self.observeSettings()
            }
        }
    }
}
