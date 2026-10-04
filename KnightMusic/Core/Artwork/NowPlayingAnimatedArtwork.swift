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
    /// The animated-artwork key for one slot, or nil when the slot can't be filled.
    static func entry(albumId: String, tall: Bool, videoURL: URL, fallbackPreview: UIImage?) async -> MPMediaItemAnimatedArtwork? {
        await make(albumId: albumId, variant: tall ? "3x4" : "1x1", videoURL: videoURL, fallbackPreview: fallbackPreview)
    }

    /// The preview is rendered up front so the system's request never comes back empty.
    /// The artwork ID carries the file's identity: the system caches animated artwork by ID (including
    /// failures), so a re-downloaded or re-encoded clip must never reuse an old ID.
    private static func make(albumId: String, variant: String, videoURL: URL, fallbackPreview: UIImage?) async -> MPMediaItemAnimatedArtwork? {
        guard let preview = await firstFrame(of: videoURL) ?? fallbackPreview else {
            Log.artwork.error("lockscreen art: no preview for \(albumId) \(variant), skipping")
            return nil
        }
        let id = "\(albumId)-\(variant)-\(fileSignature(videoURL))"
        Log.artwork.info("lockscreen art: providing \(id) -> \(videoURL.lastPathComponent)")
        return MPMediaItemAnimatedArtwork(
            artworkID: id,
            previewImageRequestHandler: { size in
                scale(preview, to: size)
            },
            videoAssetFileURLRequestHandler: { _ in
                videoURL
            }
        )
    }

    private static func fileSignature(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return "v3-\(size)-\(modified)"
    }

    private static func firstFrame(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image)
    }

    private static func scale(_ image: UIImage, to targetSize: CGSize) -> UIImage {
        guard targetSize.width > 0, targetSize.height > 0, image.size.width > 0, image.size.height > 0 else {
            return image
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1.0
        format.opaque = true
        let targetSize = CGSize(width: targetSize.width.rounded(), height: targetSize.height.rounded())
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
