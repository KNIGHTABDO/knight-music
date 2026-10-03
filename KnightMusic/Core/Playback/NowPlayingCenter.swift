import MediaPlayer
import UIKit

/// MPNowPlayingInfoCenter bridge. Elapsed time is only pushed on seek / rate change (the system extrapolates).
@MainActor
final class NowPlayingCenter {
    var artwork: ArtworkProviding?

    private var info: [String: Any] = [:]
    private var currentSongId: String?
    private var artworkTask: Task<Void, Never>?

    func setSong(_ song: Song?, isLive: Bool, duration: TimeInterval, elapsed: TimeInterval, rate: Double,
                 queueIndex: Int, queueCount: Int) {
        artworkTask?.cancel()
        guard let song else {
            clear()
            return
        }
        currentSongId = song.id
        var next: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queueCount,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if duration > 0, !isLive { next[MPMediaItemPropertyPlaybackDuration] = duration }
        if let track = song.track { next[MPMediaItemPropertyAlbumTrackNumber] = track }
        if let genre = song.genre { next[MPMediaItemPropertyGenre] = genre }
        info = next
        publish()
        guard !isLive, let provider = artwork else { return }
        let id = song.id
        artworkTask = Task { [weak self] in
            if let image = await provider.image(coverArt: song.coverArt, size: 600) {
                guard !Task.isCancelled else { return }
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self?.merge([MPMediaItemPropertyArtwork: art], songId: id)
            }
            let entries = await provider.nowPlayingEntries(for: song)
            guard !Task.isCancelled, !entries.isEmpty else { return }
            self?.merge(entries, songId: id)
        }
    }

    func updatePlayback(elapsed: TimeInterval, rate: Double) {
        guard currentSongId != nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        publish()
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    func updateDuration(_ duration: TimeInterval) {
        guard currentSongId != nil, duration > 0 else { return }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        publish()
    }

    func updateQueue(index: Int, count: Int) {
        guard currentSongId != nil else { return }
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = count
        publish()
    }

    func clear() {
        artworkTask?.cancel()
        currentSongId = nil
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func merge(_ entries: [String: Any], songId: String) {
        guard songId == currentSongId else { return }
        info.merge(entries) { _, new in new }
        publish()
    }

    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
