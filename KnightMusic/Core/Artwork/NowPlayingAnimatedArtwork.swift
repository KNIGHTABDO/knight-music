import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Builds iOS 26 `MPMediaItemAnimatedArtwork` values for the lock screen / Control Center.
/// Deliberately a nonisolated enum: MediaPlayer invokes the handlers on its own queues.
enum NowPlayingAnimatedArtwork {
    static func entries(albumId: String, artwork: AnimatedArtwork, fallbackPreview: UIImage?) async -> [String: Any] {
        var out: [String: Any] = [:]
        let squarePreview = await firstFrame(of: artwork.squareVideoURL) ?? fallbackPreview
        if let squarePreview {
            out[MPNowPlayingInfoProperty1x1AnimatedArtwork] = make(id: "\(albumId)-1x1", preview: squarePreview, video: artwork.squareVideoURL)
        }
        if let tall = artwork.tallVideoURL, let tallPreview = await firstFrame(of: tall) ?? fallbackPreview {
            out[MPNowPlayingInfoProperty3x4AnimatedArtwork] = make(id: "\(albumId)-3x4", preview: tallPreview, video: tall)
        }
        return out
    }

    private static func make(id: String, preview: UIImage, video: URL) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(
            artworkID: id,
            previewImageRequestHandler: { _ in preview },
            videoAssetFileURLRequestHandler: { _ in video }
        )
    }

    private static func firstFrame(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image)
    }
}
