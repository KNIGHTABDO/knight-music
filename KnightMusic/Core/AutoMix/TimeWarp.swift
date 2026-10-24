import AVFoundation
import CoreMedia

/// An incoming song's blend tempo baked into its item as scaled composition edits: the song plays at `rate` from
/// the mix start and eases back to 1 through the ramp steps, while the deck itself always runs at rate 1.
/// Changing an AVPlayer's rate flushes its audio output (an audible cut); scaled edits are time-stretched inside
/// the item, so the tempo glides with no cut. Maps song time (UI, lyrics, plan curves) to item time and back.
struct TimeWarp: Sendable {
    struct Span: Sendable {
        let songStart: Double
        let songEnd: Double
        let rate: Double
    }

    let spans: [Span]

    /// `rate` from `start`, then each `[time, rate]` step of `ramp`, back to 1 after the last one.
    /// Nil when the song keeps its own tempo or the steps don't fit inside `songDuration`.
    init?(start: Double, rate: Double, ramp: [[Double]], songDuration: Double) {
        var points = [(time: start, rate: rate)]
        for step in ramp where step.count >= 2 && step[0] > points[points.count - 1].time {
            points.append((step[0], step[1]))
        }
        if abs(points[points.count - 1].rate - 1) > 0.0005 {
            // No way back to the song's own tempo in the plan: glide back over 8 s after the last step.
            let from = points[points.count - 1]
            for k in 1...16 {
                points.append((from.time + 0.5 * Double(k), from.rate + (1 - from.rate) * Double(k) / 16))
            }
        }
        var spans: [Span] = []
        for (point, next) in zip(points, points.dropFirst()) where abs(point.rate - 1) > 0.0005 && point.rate > 0 {
            spans.append(Span(songStart: point.time, songEnd: next.time, rate: point.rate))
        }
        guard !spans.isEmpty, start >= 0, let last = spans.last, last.songEnd < songDuration - 0.5 else { return nil }
        self.spans = spans
    }

    func itemTime(_ songTime: Double) -> Double {
        var shift = 0.0
        for span in spans {
            guard songTime > span.songStart else { break }
            let covered = min(songTime, span.songEnd) - span.songStart
            shift += covered / span.rate - covered
        }
        return songTime + shift
    }

    func songTime(_ itemTime: Double) -> Double {
        var shift = 0.0
        for span in spans {
            let length = span.songEnd - span.songStart
            let itemStart = span.songStart + shift
            let itemLength = length / span.rate
            guard itemTime > itemStart else { break }
            if itemTime < itemStart + itemLength { return span.songStart + (itemTime - itemStart) * span.rate }
            shift += itemLength - length
        }
        return itemTime - shift
    }

    /// Song keyframes (`[[time, value], ...]`) moved onto the item's timeline.
    func itemFrames(_ frames: [[Double]]) -> [[Double]] {
        frames.map { frame in frame.count >= 2 ? [itemTime(frame[0])] + frame.dropFirst() : frame }
    }

    /// The whole song with its spans scaled. Scaled last to first, so each span still starts at its song time.
    @MainActor
    func composition(of asset: AVAsset) async throws -> AVComposition {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.noAudio }
        try output.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        for span in spans.reversed() {
            let range = CMTimeRange(start: Self.time(span.songStart), end: Self.time(span.songEnd))
            output.scaleTimeRange(range, toDuration: Self.time((span.songEnd - span.songStart) / span.rate))
        }
        return composition
    }

    enum Failure: Error { case noAudio }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }
}
