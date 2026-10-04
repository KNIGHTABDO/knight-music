import Foundation
import MediaPlayer
import Network

struct AnimatedArtwork: Hashable, Sendable {
    var squareVideoURL: URL
    var tallVideoURL: URL?

    init(squareVideoURL: URL, tallVideoURL: URL? = nil) {
        self.squareVideoURL = squareVideoURL
        self.tallVideoURL = tallVideoURL
    }
}

/// Main-actor facade over the animated artwork pipeline (lookup, download, fallback conversion, lock screen).
/// Settings keys: `animatedArtworkEnabled` (default true), `lockScreenAnimatedArtworkEnabled` (default true).
@MainActor @Observable
final class AnimatedArtworkService {
    @ObservationIgnored private let store = AnimatedArtworkStore()
    @ObservationIgnored private let wifi = UnmeteredPathMonitor()

    init() {}

    var isEnabled: Bool { Self.flag("animatedArtworkEnabled") }
    var isLockScreenEnabled: Bool { Self.flag("lockScreenAnimatedArtworkEnabled") }

    func animatedArtwork(for song: Song) async -> AnimatedArtwork? {
        guard isEnabled, let request = Self.request(for: song) else { return nil }
        return await store.resolve(request, allowDownload: wifi.isUnmetered)
    }

    /// Warm the cache for upcoming songs (one lookup per album, deduplicated).
    func prefetch(for songs: [Song]) {
        guard isEnabled else { return }
        var seen = Set<String>()
        for song in songs {
            guard let request = Self.request(for: song), seen.insert(request.albumId).inserted else { continue }
            let allow = wifi.isUnmetered
            Task.detached(priority: .utility) { [store] in
                _ = await store.resolve(request, allowDownload: allow)
            }
        }
    }

    /// MPNowPlayingInfo entries for iOS 26 lock-screen animated artwork. Empty when disabled or unavailable.
    func nowPlayingEntries(for song: Song) async -> [String: Any] {
        guard isLockScreenEnabled, let albumId = song.albumId, !albumId.isEmpty else { return [:] }
        guard await animatedArtwork(for: song) != nil else { return [:] }
        // iPhone's lock screen only shows the 3:4 slot and iPad's only the 1:1 one; anything else is ignored.
        let supported = Set(MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys)
        Log.artwork.info("lockscreen art: supported keys \(supported.sorted().joined(separator: ", "))")
        let cover = await ArtworkLoader.shared.image(coverArt: song.coverArt, size: 1200)
        var out: [String: Any] = [:]
        for (key, tall) in [(MPNowPlayingInfoProperty3x4AnimatedArtwork, true), (MPNowPlayingInfoProperty1x1AnimatedArtwork, false)]
        where supported.contains(key) {
            guard let clip = await store.lockClip(albumId: albumId, tall: tall) else {
                Log.artwork.error("lockscreen art: no \(tall ? "3:4" : "1:1") clip for album \(albumId)")
                continue
            }
            if let artwork = await NowPlayingAnimatedArtwork.entry(albumId: albumId, tall: tall, videoURL: clip, fallbackPreview: cover) {
                out[key] = artwork
            }
        }
        return out
    }

    private static func request(for song: Song) -> AnimatedArtworkRequest? {
        guard let albumId = song.albumId, !albumId.isEmpty else { return nil }
        return AnimatedArtworkRequest(albumId: albumId, artist: song.artist, album: song.album, coverArt: song.coverArt)
    }

    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// "Wi-Fi only" gate: true unless the current path is expensive (cellular / hotspot) or constrained (Low Data Mode).
final class UnmeteredPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.set(path.status == .satisfied && !path.isExpensive && !path.isConstrained)
        }
        monitor.start(queue: DispatchQueue(label: "km.artwork.path", qos: .utility))
    }

    deinit { monitor.cancel() }

    var isUnmetered: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    private func set(_ new: Bool) {
        lock.lock(); value = new; lock.unlock()
    }
}
