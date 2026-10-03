import SwiftUI

/// Custom player scrubber:
/// - 6pt capsule that expands to 12pt while dragging with spring animation
/// - White fill for elapsed progress, lighter track for buffered fraction
/// - Haptic feedback at track start and end boundaries
/// - Displays elapsed time (left), formatDescription (centered), and remaining time (right)
struct PlayerScrubberView: View {
    @Environment(PlayerEngine.self) private var player

    @State private var isDragging = false
    @State private var scrubTime: TimeInterval = 0
    @State private var wasAtStart = false
    @State private var wasAtEnd = false

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let duration = max(player.duration, 1)
                let displayTime = isDragging ? scrubTime : player.currentTime
                let progress = min(max(displayTime / duration, 0), 1)
                let bufferFraction = min(max(player.bufferedFraction, 0), 1)
                let capsuleHeight: CGFloat = isDragging ? 12 : 6

                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: capsuleHeight)

                    // Buffered progress track
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: max(0, totalWidth * bufferFraction), height: capsuleHeight)

                    // Elapsed progress track
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, totalWidth * progress), height: capsuleHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(Capsule())
                .frame(height: 28, alignment: .center)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                wasAtStart = false
                                wasAtEnd = false
                                player.beginScrubbing()
                                Haptics.impact(.light)
                            }
                            let fraction = min(max(gesture.location.x / totalWidth, 0), 1)
                            let newTime = fraction * duration
                            scrubTime = newTime

                            let atStart = fraction <= 0.005
                            let atEnd = fraction >= 0.995
                            if atStart && !wasAtStart {
                                Haptics.impact(.medium)
                            }
                            if atEnd && !wasAtEnd {
                                Haptics.impact(.medium)
                            }
                            wasAtStart = atStart
                            wasAtEnd = atEnd

                            player.scrub(to: newTime)
                        }
                        .onEnded { gesture in
                            let fraction = min(max(gesture.location.x / totalWidth, 0), 1)
                            let finalTime = fraction * duration
                            player.endScrubbing(at: finalTime)
                            scrubTime = finalTime
                            isDragging = false
                            Haptics.selection()
                        }
                )
            }
            .frame(height: 28)

            // Timestamps and audio stream format description
            HStack {
                let displayTime = isDragging ? scrubTime : player.currentTime
                Text(KMFormat.duration(displayTime))
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.secondaryLabel)

                Spacer()

                if !player.formatDescription.isEmpty {
                    Text(player.formatDescription)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }

                Spacer()

                let remaining = max(0, player.duration - displayTime)
                Text(player.duration > 0 ? "-\(KMFormat.duration(remaining))" : "--:--")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }
}
