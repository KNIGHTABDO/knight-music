import AVFoundation
import CoreGraphics

/// Makes a clip of exactly the shape a lock-screen slot asks for (3:4 on iPhone, 1:1 on iPad).
/// The system drops animated artwork whose clip is the wrong shape, so a square-only album gets a centre-cropped
/// 3:4 copy (and a tall-only one a square copy). Clips already within 2 % of the shape are used untouched.
enum LockScreenClip {
    private static let aspectSlack: CGFloat = 0.02

    /// `source` itself when it already fits, otherwise a cropped copy written to `cropURL` (cached on disk).
    static func clip(from source: URL, aspect: CGFloat, cropURL: URL) async -> URL? {
        if FileManager.default.fileExists(atPath: cropURL.path) { return cropURL }
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let properties = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        else {
            Log.artwork.error("lockscreen clip: no video track in \(source.lastPathComponent)")
            return nil
        }
        let (natural, transform, frameRate, range) = properties
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let width = abs(shown.width), height = abs(shown.height)
        guard width >= 2, height >= 2 else { return nil }
        if abs(width / height - aspect) < aspectSlack { return source }

        let render = width / height > aspect
            ? CGSize(width: even(height * aspect), height: even(height))
            : CGSize(width: even(width), height: even(width / aspect))
        let upright = transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
        let centred = upright.concatenating(CGAffineTransform(translationX: (render.width - width) / 2,
                                                              y: (render.height - height) / 2))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(centred, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = render
        composition.frameDuration = CMTime(value: 1, timescale: frameRate > 1 ? CMTimeScale(frameRate.rounded()) : 30)
        composition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let part = cropURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part.mp4")
        export.outputURL = part
        export.outputFileType = .mp4
        export.videoComposition = composition
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            Log.artwork.error("lockscreen clip: crop failed \(export.error?.localizedDescription ?? "unknown")")
            try? FileManager.default.removeItem(at: part)
            return nil
        }
        try? FileManager.default.removeItem(at: cropURL)
        do {
            try FileManager.default.moveItem(at: part, to: cropURL)
        } catch {
            Log.artwork.error("lockscreen clip: could not keep crop \(error.localizedDescription)")
            return nil
        }
        Log.artwork.info("lockscreen clip: cropped \(Int(width))x\(Int(height)) -> \(Int(render.width))x\(Int(render.height))")
        return cropURL
    }

    /// H.264 wants even dimensions.
    private static func even(_ value: CGFloat) -> CGFloat { 2 * (value / 2).rounded(.down) }
}
