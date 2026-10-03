import SwiftUI

/// Plain transport controls (no glass background) placed over the player background:
/// - Shuffle (accent when active)
/// - Previous (bounce symbol effect on tap)
/// - Play/Pause (large 44pt symbol with replace symbol effect transition)
/// - Next (bounce symbol effect on tap)
/// - Repeat (repeat / repeat.1, accent when active)
struct PlayerTransportBar: View {
    @Environment(PlayerEngine.self) private var player

    @State private var prevTapCount = 0
    @State private var nextTapCount = 0

    var body: some View {
        HStack {
            // Shuffle toggle
            Button {
                Haptics.impact(.light)
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.shuffleEnabled ? Theme.accent : Color.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Previous track
            Button {
                Haptics.impact(.light)
                prevTapCount += 1
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .symbolEffect(.bounce, value: prevTapCount)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Play / Pause toggle
            Button {
                Haptics.impact(.medium)
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 54, minHeight: 54)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Next track
            Button {
                Haptics.impact(.light)
                nextTapCount += 1
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .symbolEffect(.bounce, value: nextTapCount)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Repeat toggle (off -> all -> one)
            Button {
                Haptics.impact(.light)
                player.cycleRepeat()
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatMode != .off ? Theme.accent : Color.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
