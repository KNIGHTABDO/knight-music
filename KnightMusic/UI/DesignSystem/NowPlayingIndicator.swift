import SwiftUI

/// Four equalizer bars. Bounces while `isAnimating`, rests low when paused.
struct NowPlayingIndicator: View {
    var isAnimating: Bool = true
    var color: Color = Theme.accent
    var size: CGFloat = 16

    private let speeds: [Double] = [5.1, 6.7, 4.3, 7.4]
    private let phases: [Double] = [0, 1.3, 2.4, 0.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: size * 0.12) {
                ForEach(0..<4, id: \.self) { i in
                    let level = isAnimating ? 0.25 + 0.75 * abs(sin(t * speeds[i] * 0.5 + phases[i])) : 0.2
                    Capsule()
                        .fill(color)
                        .frame(width: size * 0.17, height: size * level)
                }
            }
            .frame(width: size, height: size, alignment: .bottom)
            .animation(.smooth(duration: 0.25), value: isAnimating)
        }
        .accessibilityLabel("Now playing")
    }
}
