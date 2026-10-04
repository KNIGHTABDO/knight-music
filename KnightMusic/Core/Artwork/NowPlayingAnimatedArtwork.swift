import Foundation
import AVFoundation
import MediaPlayer
import UIKit

extension Notification.Name {
    static let animatedArtworkDidBecomeReady = Notification.Name("km.animatedArtworkDidBecomeReady")
}

/// Builds iOS 26 `MPMediaItemAnimatedArtwork` values for the lock screen / Control Center.
/// Deliberately a nonisolated enum: MediaPlayer invokes the handlers on its own queues.
enum NowPlayingAnimatedArtwork {
    private static let previewCache = NSCache<NSString, UIImage>()

    static func entries(albumId: String, artwork: AnimatedArtwork, fallbackPreview: UIImage?) async -> [String: Any] {
        let squareURL = artwork.lockSquareVideoURL ?? artwork.squareVideoURL
        let tallURL = artwork.lockTallVideoURL ?? artwork.tallVideoURL
        return await entries(albumId: albumId, lockSquareURL: squareURL, lockTallURL: tallURL, fallbackPreview: fallbackPreview)
    }

    static func entries(albumId: String, lockSquareURL: URL, lockTallURL: URL?, fallbackPreview: UIImage?) async -> [String: Any] {
        var out: [String: Any] = [:]
        out[MPNowPlayingInfoProperty1x1AnimatedArtwork] = make(
            id: "\(albumId)-square",
            videoURL: lockSquareURL,
            fallbackPreview: fallbackPreview
        )
        if let lockTallURL {
            out[MPNowPlayingInfoProperty3x4AnimatedArtwork] = make(
                id: "\(albumId)-tall",
                videoURL: lockTallURL,
                fallbackPreview: fallbackPreview
            )
        }
        return out
    }

    private static func make(id: String, videoURL: URL, fallbackPreview: UIImage?) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(
            artworkID: id,
            previewImageRequestHandler: { size in
                let w = Int(size.width)
                let h = Int(size.height)
                Log.artwork.info("preview handler called size=\(w)x\(h)")
                return await generatePreview(for: videoURL, size: size, fallback: fallbackPreview)
            },
            videoAssetFileURLRequestHandler: { size in
                let w = Int(size.width)
                let h = Int(size.height)
                Log.artwork.info("video handler called size=\(w)x\(h) -> \(videoURL.lastPathComponent)")
                return videoURL
            }
        )
    }

    private static func generatePreview(for videoURL: URL, size: CGSize, fallback: UIImage?) async -> UIImage? {
        let key = "\(videoURL.path)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = previewCache.object(forKey: key) {
            return cached
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if size.width > 0 && size.height > 0 {
            generator.maximumSize = size
        }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        if let result = try? await generator.image(at: .zero) {
            let image = UIImage(cgImage: result.image)
            previewCache.setObject(image, forKey: key)
            return image
        }

        guard let fallback else { return nil }
        let scaled = scale(fallback, to: size)
        previewCache.setObject(scaled, forKey: key)
        return scaled
    }

    private static func scale(_ image: UIImage, to targetSize: CGSize) -> UIImage {
        guard targetSize.width > 0, targetSize.height > 0, image.size.width > 0, image.size.height > 0 else {
            return image
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            let aspectWidth = targetSize.width / image.size.width
            let aspectHeight = targetSize.height / image.size.height
            let scaleFactor = max(aspectWidth, aspectHeight)
            let scaledWidth = image.size.width * scaleFactor
            let scaledHeight = image.size.height * scaleFactor
            let origin = CGPoint(
                x: (targetSize.width - scaledWidth) / 2.0,
                y: (targetSize.height - scaledHeight) / 2.0
            )
            image.draw(in: CGRect(origin: origin, size: CGSize(width: scaledWidth, height: scaledHeight)))
        }
    }
}
