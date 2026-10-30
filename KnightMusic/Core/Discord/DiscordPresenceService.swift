import Foundation
import UIKit

/// Coordinates real-time Discord Rich Presence by observing PlayerEngine
/// and sending immediate Gateway presence updates.
@MainActor @Observable
final class DiscordPresenceService {
    let settings = DiscordSettings()
    let client = DiscordGatewayClient()

    private weak var app: AppModel?
    private weak var player: PlayerEngine?
    private var lastSentSongId: String?
    private var lastSentState: Bool? // isPlaying
    private var lastSentTime: TimeInterval = 0

    // In-memory artwork cache: song.id -> "mp:external/..."
    private var cachedArtwork: [String: String] = [:]
    private var resolvingSongId: String?

    init() {
        client.onStateChange = { [weak self] state in
            self?.settings.state = state
        }
    }

    func start(app: AppModel) {
        self.app = app
        self.player = app.player

        player?.onSeekFinished = { [weak self] _ in
            self?.update()
        }

        observeSettings()
        observePlayer()
        update()
    }

    func testConnection() async {
        guard !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            settings.state = .error("Please enter a Discord token first.")
            return
        }

        settings.state = .connecting
        client.disconnect()
        client.connect(token: settings.token)

        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if settings.state != .connecting {
                return
            }
        }

        if settings.state == .connecting {
            settings.state = .error("Connection timed out. Check token and internet.")
        }
    }

    // MARK: - Update Engine

    func update() {
        guard settings.isConfigured else {
            if client.isConnected {
                client.disconnect()
            }
            settings.state = .disconnected
            return
        }

        guard let player else { return }

        if !client.isConnected {
            client.connect(token: settings.token)
        }

        guard let song = player.currentSong, player.isPlaying else {
            // Paused or stopped
            lastSentSongId = nil
            lastSentState = false
            if settings.clearOnPause {
                client.updatePresence(activities: [])
            } else if let song = player.currentSong {
                let activity = buildActivity(song: song, isPlaying: false, player: player)
                client.updatePresence(activities: [activity])
            } else {
                client.updatePresence(activities: [])
            }
            return
        }

        lastSentSongId = song.id
        lastSentState = true
        lastSentTime = player.currentTime

        let activity = buildActivity(song: song, isPlaying: true, player: player)
        client.updatePresence(activities: [activity])
    }

    private func buildActivity(song: Song, isPlaying: Bool, player: PlayerEngine) -> DiscordActivity {
        let name = settings.activityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Knight Music" : settings.activityName
        let details = song.title
        let state = song.artist ?? ""

        var timestamps: DiscordActivity.Timestamps? = nil
        if isPlaying {
            let elapsed = max(0, player.currentTime)
            let duration = max(0, player.duration)
            let startMs = Int64((Date().timeIntervalSince1970 - elapsed) * 1000)
            let endMs = duration > 0 ? startMs + Int64(duration * 1000) : nil
            timestamps = DiscordActivity.Timestamps(start: startMs, end: endMs)
        }

        var assets: DiscordActivity.Assets? = nil
        if settings.showArtwork {
            let albumText = song.album ?? song.title
            if let mpAsset = cachedArtwork[song.id] {
                assets = DiscordActivity.Assets(
                    large_image: mpAsset,
                    large_text: albumText
                )
            } else {
                // Trigger background resolution and registration with Discord
                resolveArtworkInBackground(for: song)
            }
        }

        return DiscordActivity(
            name: name,
            type: 2, // 2 = Listening to
            application_id: settings.effectiveApplicationId,
            details: details,
            state: state.isEmpty ? nil : state,
            timestamps: timestamps,
            assets: assets
        )
    }

    private func resolveArtworkInBackground(for song: Song) {
        guard settings.showArtwork, settings.isConfigured else { return }
        let songId = song.id
        guard resolvingSongId != songId, cachedArtwork[songId] == nil else { return }
        resolvingSongId = songId

        let directURL = resolveArtworkURL(for: song)
        let token = settings.token
        let appId = settings.effectiveApplicationId

        Task { @MainActor [weak self] in
            guard let self else { return }
            let asset = await DiscordAssetResolver.shared.resolveArtwork(
                songId: song.id,
                artist: song.artist,
                title: song.title,
                album: song.album,
                directURL: directURL,
                token: token,
                applicationId: appId
            )
            self.resolvingSongId = nil
            if let asset {
                self.cachedArtwork[songId] = asset
                // If this song is still playing, update the presence to show the artwork immediately
                if self.player?.currentSong?.id == songId {
                    self.update()
                }
            }
        }
    }

    private func resolveArtworkURL(for song: Song) -> String? {
        if let cover = song.coverArt {
            if cover.hasPrefix("http://") || cover.hasPrefix("https://") {
                return cover
            }
            if let url = ArtworkLoader.shared.coverArtURL(id: cover, size: 600) {
                return url.absoluteString
            }
        }

        if let url = ArtworkLoader.shared.coverArtURL(id: song.id, size: 600) {
            return url.absoluteString
        }

        return nil
    }

    // MARK: - Observations

    private func observeSettings() {
        withObservationTracking {
            _ = settings.isEnabled
            _ = settings.token
            _ = settings.showArtwork
            _ = settings.clearOnPause
            _ = settings.activityName
            _ = settings.applicationId
        } onChange: {
            Task { @MainActor [weak self] in
                self?.update()
                self?.observeSettings()
            }
        }
    }

    private func observePlayer() {
        guard let player else { return }
        withObservationTracking {
            _ = player.currentSong?.id
            _ = player.isPlaying
            _ = player.duration
            _ = player.isScrubbing
        } onChange: {
            Task { @MainActor [weak self] in
                self?.update()
                self?.observePlayer()
            }
        }
    }
}
