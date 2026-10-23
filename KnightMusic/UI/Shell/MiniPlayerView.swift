import SwiftUI

/// Apple Music style mini player accessory shown in the bottom bar.
/// Tap or swipe up opens the full player, swipe left/right skips, long-press shows the song menu.
struct MiniPlayerView: View {
    var namespace: Namespace.ID

    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Horizontal offset of the title while the user swipes to skip.
    @State private var swipeOffset: CGFloat = 0

    private static let skipThreshold: CGFloat = 60

    private var isInline: Bool {
        placement == .inline
    }

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                ArtworkView(coverArt: song.coverArt, pointSize: 40, cornerRadius: 6)
                    .matchedTransitionSource(id: "nowPlayingArtwork", in: namespace)

                titles(for: song)
                    .offset(x: swipeOffset)
                    .opacity(1 - min(abs(swipeOffset) / 160, 0.6))
                    .id(song.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))

                Spacer(minLength: 8)

                controls
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .contentShape(Rectangle())
            .animation(.snappy, value: song.id)
            .onTapGesture {
                ui.isPlayerPresented = true
            }
            .simultaneousGesture(swipeGesture)
            .contextMenu {
                SongActionsMenu(song: song)
            }
            .libraryDropDestination { songs in
                player.enqueue(songs, next: true)
                ui.showToast(songs.count == 1 ? "Playing Next" : "Playing \(songs.count) Songs Next")
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Player") { ui.isPlayerPresented = true }
        }
    }

    @ViewBuilder
    private func titles(for song: Song) -> some View {
        if isInline {
            Text(song.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let artist = song.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: sizeClass == .regular ? 24 : 18) {
            if !isInline && sizeClass == .regular {
                controlButton(
                    symbol: "shuffle",
                    size: 18, weight: .medium,
                    tint: player.shuffleEnabled ? Theme.accent : Theme.secondaryLabel,
                    label: player.shuffleEnabled ? "Shuffle On" : "Shuffle Off"
                ) {
                    Haptics.selection()
                    player.toggleShuffle()
                }
            }

            if !isInline {
                controlButton(symbol: "backward.fill", size: 18, weight: .semibold, tint: Theme.label, label: "Previous") {
                    Haptics.impact(.light)
                    player.previous()
                }
            }

            Button {
                Haptics.impact(.medium)
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            controlButton(symbol: "forward.fill", size: 18, weight: .semibold, tint: Theme.label, label: "Next") {
                Haptics.impact(.light)
                player.next()
            }

            if !isInline && sizeClass == .regular {
                controlButton(
                    symbol: player.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 18, weight: .medium,
                    tint: player.repeatMode != .off ? Theme.accent : Theme.secondaryLabel,
                    label: "Repeat"
                ) {
                    Haptics.selection()
                    player.cycleRepeat()
                }
            }
        }
    }

    private func controlButton(
        symbol: String,
        size: CGFloat,
        weight: Font.Weight,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) else { return }
                // Rubber band beyond the threshold so the title never runs off the bar.
                let limit = Self.skipThreshold * 1.5
                swipeOffset = abs(dx) < limit ? dx : (dx > 0 ? 1 : -1) * (limit + (abs(dx) - limit) * 0.2)
            }
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if dy < -20 && abs(dy) > abs(dx) {
                    ui.isPlayerPresented = true
                } else if abs(dx) > abs(dy), abs(dx) > Self.skipThreshold || abs(value.predictedEndTranslation.width) > 160 {
                    Haptics.impact(.light)
                    if dx < 0 {
                        player.next()
                    } else {
                        player.previous()
                    }
                }
                withAnimation(.snappy) { swipeOffset = 0 }
            }
    }
}
