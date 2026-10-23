import SwiftUI

/// Custom player scrubber (Apple Music style):
/// - 5pt capsule that thickens to 10pt and brightens while dragging
/// - Touch jumps to the finger, then the drag is relative; sliding the finger down slows it
///   (Hi-Speed → Half → Quarter → Fine scrubbing), shown in place of the format text
/// - Haptic feedback at the start/end boundaries and when the scrubbing speed changes
struct PlayerScrubberView: View {
    @Environment(PlayerEngine.self) private var player

    @State private var isDragging = false
    @State private var scrubTime: TimeInterval = 0
    @State private var lastX: CGFloat = 0
    @State private var speed: ScrubSpeed = .full
    @State private var wasAtStart = false
    @State private var wasAtEnd = false

    enum ScrubSpeed: Equatable {
        case full, half, quarter, fine

        init(verticalDistance: CGFloat) {
            switch verticalDistance {
            case ..<50: self = .full
            case ..<100: self = .half
            case ..<150: self = .quarter
            default: self = .fine
            }
        }

        var rate: Double {
            switch self {
            case .full: 1
            case .half: 0.5
            case .quarter: 0.25
            case .fine: 0.1
            }
        }

        var label: String {
            switch self {
            case .full: "Hi-Speed Scrubbing"
            case .half: "Half-Speed Scrubbing"
            case .quarter: "Quarter-Speed Scrubbing"
            case .fine: "Fine Scrubbing"
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let totalWidth = max(geo.size.width, 1)
                let duration = max(player.duration, 1)
                let displayTime = isDragging ? scrubTime : player.currentTime
                let progress = min(max(displayTime / duration, 0), 1)
                let bufferFraction = min(max(player.bufferedFraction, 0), 1)
                let capsuleHeight: CGFloat = isDragging ? 10 : 5

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(isDragging ? 0.24 : 0.18))
                        .frame(height: capsuleHeight)

                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: max(0, totalWidth * bufferFraction), height: capsuleHeight)

                    Capsule()
                        .fill(Color.white.opacity(isDragging ? 1 : 0.9))
                        .frame(width: max(0, totalWidth * progress), height: capsuleHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(Capsule())
                .padding(.horizontal, isDragging ? -6 : 0)
                .frame(height: 24, alignment: .center)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
                .gesture(scrubGesture(totalWidth: totalWidth, duration: duration))
                .accessibilityElement()
                .accessibilityLabel("Track Position")
                .accessibilityValue(KMFormat.duration(displayTime))
                .accessibilityAdjustableAction { direction in
                    let step: TimeInterval = direction == .increment ? 10 : -10
                    player.seek(to: min(max(player.currentTime + step, 0), duration))
                }
            }
            .frame(height: 24)

            HStack {
                let displayTime = isDragging ? scrubTime : player.currentTime
                Text(KMFormat.duration(displayTime))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(isDragging ? 1 : 0.85))

                Spacer()

                Group {
                    if isDragging {
                        Text(speed.label)
                            .foregroundStyle(Color.white.opacity(0.85))
                    } else if !player.formatDescription.isEmpty {
                        Text(player.formatDescription)
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.2), value: isDragging)
                .animation(.smooth(duration: 0.2), value: speed)

                Spacer()

                let remaining = max(0, player.duration - displayTime)
                Text(player.duration > 0 ? "-\(KMFormat.duration(remaining))" : "--:--")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(isDragging ? 1 : 0.85))
            }
        }
    }

    private func scrubGesture(totalWidth: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let x = gesture.location.x
                if !isDragging {
                    isDragging = true
                    wasAtStart = false
                    wasAtEnd = false
                    speed = .full
                    lastX = x
                    scrubTime = Double(min(max(x / totalWidth, 0), 1)) * duration
                    player.beginScrubbing()
                    Haptics.impact(.light)
                } else {
                    let newSpeed = ScrubSpeed(verticalDistance: max(0, gesture.translation.height))
                    if newSpeed != speed {
                        speed = newSpeed
                        Haptics.selection()
                    }
                    let delta = Double((x - lastX) / totalWidth) * duration * speed.rate
                    lastX = x
                    scrubTime = min(max(scrubTime + delta, 0), duration)
                }

                let fraction = scrubTime / duration
                let atStart = fraction <= 0.005
                let atEnd = fraction >= 0.995
                if atStart && !wasAtStart { Haptics.impact(.medium) }
                if atEnd && !wasAtEnd { Haptics.impact(.medium) }
                wasAtStart = atStart
                wasAtEnd = atEnd

                player.scrub(to: scrubTime)
            }
            .onEnded { _ in
                player.endScrubbing(at: scrubTime)
                isDragging = false
                speed = .full
                Haptics.selection()
            }
    }
}
