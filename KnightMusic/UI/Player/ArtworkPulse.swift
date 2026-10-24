import SwiftUI

/// Makes the player artwork move with the music: follows the measured loudness when the audio tap
/// is running, otherwise beats at the song's BPM, otherwise breathes slowly.
struct ArtworkPulse: ViewModifier {
    let mode: Look.Pulse
    let bpm: Int?

    @Environment(PlayerEngine.self) private var player
    @State private var smoother = LevelSmoother()

    func body(content: Content) -> some View {
        if mode == .off || !player.isPlaying {
            content
        } else {
            TimelineView(.animation) { context in
                content.scaleEffect(scale(at: context.date))
            }
        }
    }

    private func scale(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        switch mode {
        case .off:
            return 1
        case .breathe:
            return 1 + 0.025 * CGFloat(sin(t * 2 * .pi / 5))
        case .beat:
            if let level = player.audioLevel {
                return 1 + 0.06 * CGFloat(smoother.next(level))
            }
            guard let bpm, bpm > 40 else {
                return 1 + 0.025 * CGFloat(sin(t * 2 * .pi / 5))
            }
            // A quick kick on every beat that decays before the next one.
            let phase = (t * Double(bpm) / 60).truncatingRemainder(dividingBy: 1)
            return 1 + 0.035 * CGFloat(exp(-phase * 6))
        }
    }
}

/// Fast attack, slow release, normalised against the recent peak so quiet and loud masters move alike.
private final class LevelSmoother {
    private var value: Float = 0
    private var peak: Float = 0.05

    func next(_ level: Float) -> Float {
        peak = max(level, peak * 0.995, 0.02)
        let target = min(level / peak, 1)
        value += (target - value) * (target > value ? 0.6 : 0.12)
        // Emphasise the hits: only the top of the range moves the cover much.
        return value * value
    }
}
