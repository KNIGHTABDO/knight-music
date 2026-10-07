import Foundation
import UIKit
import Nuke
import os

/// Anything that can build a Subsonic `getCoverArt` URL. `SubsonicClient` conforms; the integrator calls
/// `ArtworkLoader.configure(provider:)` whenever the active client changes.
protocol CoverArtURLProviding: Sendable {
    func coverArtURL(id: String, size: Int?) -> URL
}

extension SubsonicClient: CoverArtURLProviding {}

/// Nuke pipeline tuned for a music app.
/// Subsonic cover URLs carry a random salt/token, so the cache key is built from (coverArt id, size bucket)
/// instead of the URL; otherwise nothing would ever hit the cache.
final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()
    /// Server-side sizes (pixels) we ever ask for.
    static let buckets = [120, 300, 600, 1000, 1500]

    let pipeline: ImagePipeline
    private let prefetcher: ImagePrefetcher
    private let lock = NSLock()
    private var provider: CoverArtURLProviding?
    private let log = Logger(subsystem: "com.knightabdo.knightmusic", category: "artwork")

    private init() {
        let memory = ImageCache()
        memory.costLimit = 200 * 1024 * 1024
        memory.countLimit = 800

        var config = ImagePipeline.Configuration()
        config.imageCache = memory
        do {
            let disk = try DataCache(name: "com.knightabdo.knightmusic.artwork")
            disk.sizeLimit = 600 * 1024 * 1024
            config.dataCache = disk
        } catch {
            Log.artwork.error("Failed to initialize artwork disk cache: \(error)")
        }
        config.dataCachePolicy = .automatic
        config.isDecompressionEnabled = true
        config.isTaskCoalescingEnabled = true

        let session = DataLoader.defaultConfiguration
        session.urlCache = nil // our own DataCache is the single disk cache
        config.dataLoader = DataLoader(configuration: session)

        let pipeline = ImagePipeline(configuration: config)
        self.pipeline = pipeline
        prefetcher = ImagePrefetcher(pipeline: pipeline, destination: .memoryCache, maxConcurrentRequestCount: 4)
        ImagePipeline.shared = pipeline
    }

    static func configure(provider: CoverArtURLProviding?) {
        shared.setProvider(provider)
    }

    func setProvider(_ provider: CoverArtURLProviding?) {
        lock.lock(); self.provider = provider; lock.unlock()
    }

    private var currentProvider: CoverArtURLProviding? {
        lock.lock(); defer { lock.unlock() }
        return provider
    }

    /// Smallest bucket that covers `pixels`, capped at the largest bucket.
    static func bucket(forPixels pixels: Int) -> Int {
        buckets.first(where: { $0 >= pixels }) ?? buckets[buckets.count - 1]
    }

    /// Un-cached URL straight from the provider (original size when `size` is nil). Used by the animated fallback.
    func coverArtURL(id: String, size: Int?) -> URL? {
        currentProvider?.coverArtURL(id: id, size: size)
    }

    func request(coverArt: String?, pointSize: CGFloat, scale: CGFloat = 3) -> ImageRequest? {
        guard let id = coverArt, !id.isEmpty else { return nil }
        return request(coverArt: id, pixels: Int((pointSize * scale).rounded(.up)))
    }

    func request(coverArt id: String, pixels: Int) -> ImageRequest? {
        guard let provider = currentProvider else { return nil }
        let bucket = Self.bucket(forPixels: pixels)
        let url = provider.coverArtURL(id: id, size: bucket)
        return ImageRequest(
            url: url,
            processors: [ImageProcessors.Resize(size: CGSize(width: bucket, height: bucket), unit: .pixels, contentMode: .aspectFill, crop: false, upscale: false)],
            userInfo: [.imageIdKey: "cover-\(id)-\(bucket)"]
        )
    }

    /// `size` is in pixels (a bucket is chosen for it).
    func image(coverArt: String?, size: Int) async -> UIImage? {
        guard let id = coverArt, !id.isEmpty, let req = request(coverArt: id, pixels: size) else { return nil }
        do { return try await pipeline.image(for: req) } catch {
            log.error("cover \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func prefetch(coverArts: [String?], pointSize: CGFloat, scale: CGFloat = 3) {
        let reqs = coverArts.compactMap { request(coverArt: $0, pointSize: pointSize, scale: scale) }
        guard !reqs.isEmpty else { return }
        prefetcher.startPrefetching(with: reqs)
    }

    func cancelPrefetch(coverArts: [String?], pointSize: CGFloat, scale: CGFloat = 3) {
        let reqs = coverArts.compactMap { request(coverArt: $0, pointSize: pointSize, scale: scale) }
        guard !reqs.isEmpty else { return }
        prefetcher.stopPrefetching(with: reqs)
    }
}
