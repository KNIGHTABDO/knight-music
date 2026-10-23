import MediaPlayer
import UIKit

/// MPNowPlayingInfoCenter bridge. Elapsed time is only pushed on seek / rate change (the system extrapolates).
@MainActor
final class NowPlayingCenter {
    var artwork: ArtworkProviding?

    private var info: [String: Any] = [:]
    private var currentSong: Song?
    private var currentSongId: String?
    private var artworkTask: Task<Void, Never>?
    private var readyObserver: (any NSObjectProtocol)?

    init() {
        readyObserver = nil
        readyObserver = NotificationCenter.default.addObserver(
            forName: .animatedArtworkDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let albumId = note.userInfo?["albumId"] as? String else { return }
            self?.handleAnimatedArtworkReady(albumId: albumId)
        }
    }

    deinit {
        if let readyObserver {
            NotificationCenter.default.removeObserver(readyObserver)
        }
    }

    func setSong(_ song: Song?, isLive: Bool, duration: TimeInterval, elapsed: TimeInterval, rate: Double,
                 queueIndex: Int, queueCount: Int) {
        artworkTask?.cancel()
        guard let song else {
            clear()
            return
        }
        currentSong = song
        currentSongId = song.id
        var next: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if let artist = song.artist, !artist.isEmpty { next[MPMediaItemPropertyArtist] = artist }
        if let album = song.album, !album.isEmpty { next[MPMediaItemPropertyAlbumTitle] = album }
        if let track = song.track { next[MPMediaItemPropertyAlbumTrackNumber] = track }
        if let genre = song.genre { next[MPMediaItemPropertyGenre] = genre }

        if !isLive {
            next[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            next[MPNowPlayingInfoPropertyPlaybackRate] = rate
            next[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            next[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
            if duration > 0 { next[MPMediaItemPropertyPlaybackDuration] = duration }
        }

        // If the cover is already in the cache, attach it synchronously in the same publish
        if !isLive, let provider = artwork, let cached = provider.cachedImage(coverArt: song.coverArt, size: 600) {
            next[MPMediaItemPropertyArtwork] = Self.makeArtwork(image: cached)
        }

        info = next
        publish()
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused

        guard !isLive, let provider = artwork else { return }
        let id = song.id
        artworkTask = Task { [weak self] in
            if self?.info[MPMediaItemPropertyArtwork] == nil,
               let image = await provider.image(coverArt: song.coverArt, size: 600) {
                guard !Task.isCancelled, self?.currentSongId == id else { return }
                self?.merge([MPMediaItemPropertyArtwork: Self.makeArtwork(image: image)], songId: id)
            }
            let entries = await provider.nowPlayingEntries(for: song)
            guard !Task.isCancelled, self?.currentSongId == id, !entries.isEmpty else { return }
            self?.merge(entries, songId: id)
        }
    }

    func updatePlayback(elapsed: TimeInterval, rate: Double, state: MPNowPlayingPlaybackState? = nil) {
        guard currentSongId != nil else { return }
        let isLive = (info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool) == true
        if !isLive {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        }
        publish()
        if let state {
            MPNowPlayingInfoCenter.default().playbackState = state
        } else {
            MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
        }
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
        currentSong = nil
        currentSongId = nil
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func handleAnimatedArtworkReady(albumId: String) {
        guard let song = currentSong, song.albumId == albumId, song.id == currentSongId else { return }
        guard let provider = artwork else { return }
        let id = song.id
        Task { [weak self] in
            let entries = await provider.nowPlayingEntries(for: song)
            guard !Task.isCancelled, self?.currentSongId == id, !entries.isEmpty else { return }
            self?.merge(entries, songId: id)
        }
    }

    private func merge(_ entries: [String: Any], songId: String) {
        guard songId == currentSongId else { return }
        info.merge(entries) { _, new in new }
        publish()
    }

    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let keyList = info.keys.sorted().joined(separator: ", ")
        Log.artwork.info("published keys: \(keyList)")
    }

    /// Nonisolated so the request handler carries no main-actor isolation: MediaPlayer calls it on a background
    /// queue (CarPlay, lock screen), where an inherited isolation check traps.
    private nonisolated static func makeArtwork(image: UIImage) -> MPMediaItemArtwork {
        let source = standardBitmap(image, size: image.size)
        return MPMediaItemArtwork(boundsSize: source.size) { requestedSize in
            Log.artwork.info("Now Playing artwork requested at \(requestedSize.width)x\(requestedSize.height)")
            guard requestedSize.width > 0, requestedSize.height > 0,
                  requestedSize.width < source.size.width || requestedSize.height < source.size.height else { return source }
            return standardBitmap(source, size: requestedSize)
        }
    }

    /// Redraws into an 8-bit sRGB bitmap at scale 1. Decoded covers can be wide-gamut or extended-range, which
    /// the Now Playing XPC transfer to CarPlay and the lock screen does not always carry.
    private nonisolated static func standardBitmap(_ image: UIImage, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let pixels = CGSize(width: (size.width * image.scale).rounded(), height: (size.height * image.scale).rounded())
        return UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixels))
        }
    }
}
