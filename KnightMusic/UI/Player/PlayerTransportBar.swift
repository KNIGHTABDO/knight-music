import SwiftUI

/// Plain transport controls (no glass background) placed over the player background:
/// - Shuffle (accent when active)
/// - Previous (bounce symbol effect on tap)
/// - Play/Pause (large 44pt symbol with replace symbol effect transition)
/// - Next (bounce symbol effect on tap)
/// - Repeat (repeat / repeat.1, accent when active)
struct PlayerTransportBar: View {
    @Environment(PlayerEngine.self) private var player

    @State private var showSleepTimer = false
    @State private var prevTapCount = 0
    @State private var nextTapCount = 0

    private func seek(by seconds: TimeInterval) {
        Haptics.impact(.light)
        player.seek(to: player.currentTime + seconds)
    }

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
            .buttonStyle(TransportButtonStyle())

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
            .highPriorityGesture(LongPressGesture().onEnded { _ in seek(by: -30) })
            .help("Long-press to skip back 30 seconds")
            .accessibilityLabel("Previous Song")
            .accessibilityAction(named: "Skip Back 30 Seconds") { seek(by: -30) }
            .buttonStyle(TransportButtonStyle())

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
                    .frame(minWidth: 64, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .highPriorityGesture(LongPressGesture().onEnded { _ in showSleepTimer = true })
            .help("Long-press for sleep timer")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityAction(named: "Sleep Timer") { showSleepTimer = true }
            .confirmationDialog("Sleep Timer", isPresented: $showSleepTimer, titleVisibility: .visible) {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) Minutes") { player.sleepTimer.start(minutes: minutes) }
                }
                Button("End of Song") { player.sleepTimer.startEndOfSong() }
                Button("Off") { player.sleepTimer.cancel() }
                Button("Cancel", role: .cancel) {}
            }
            .buttonStyle(TransportButtonStyle())

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
            .highPriorityGesture(LongPressGesture().onEnded { _ in seek(by: 30) })
            .help("Long-press to skip forward 30 seconds")
            .accessibilityLabel("Next Song")
            .accessibilityAction(named: "Skip Forward 30 Seconds") { seek(by: 30) }
            .buttonStyle(TransportButtonStyle())

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
            .buttonStyle(TransportButtonStyle())
        }
        .padding(.horizontal, Theme.margin + 4)
    }
}

/// Responsive spring button style for player controls providing tactile feedback
struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
