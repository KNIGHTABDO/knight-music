import SwiftUI

/// The player's artwork card: shrinks when paused, follows a horizontal swipe and skips past a
/// threshold, and slides the next cover in from the side it came from.
struct PlayerArtworkStage: View {
    let song: Song
    let side: CGFloat
    var animatedVideoURL: URL?

    @Environment(PlayerEngine.self) private var player
    @State private var shownSongId: String?

    var body: some View {
        // The previous song is first in `upcoming` right after going back.
        let cameFromNext = shownSongId != nil && player.upcoming.first?.song.id == shownSongId

        ZStack {
            card
                .id(song.id)
                .transition(.asymmetric(
                    insertion: .move(edge: cameFromNext ? .leading : .trailing).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.9))
                ))
        }
        .frame(width: side, height: side)
        .scaleEffect(player.isPlaying ? 1.0 : 0.85)
        .shadow(color: .black.opacity(player.isPlaying ? 0.4 : 0.25), radius: player.isPlaying ? 28 : 16, x: 0, y: player.isPlaying ? 14 : 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: song.id)
        .modifier(SkipSwipeModifier(movesContent: true))
        .onChange(of: song.id, initial: true) { _, newId in
            shownSongId = newId
        }
    }

    @ViewBuilder
    private var card: some View {
        if let animatedVideoURL {
            AnimatedArtworkView(url: animatedVideoURL)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ArtworkView(coverArt: song.coverArt, pointSize: side, cornerRadius: 12)
                .frame(width: side, height: side)
        }
    }
}

/// Horizontal swipe to change tracks: left = next, right = previous. When `movesContent`
/// is set the view follows the finger (rubber-banded) and springs back.
struct SkipSwipeModifier: ViewModifier {
    var movesContent: Bool

    @Environment(PlayerEngine.self) private var player
    @State private var dragX: CGFloat = 0

    private static let threshold: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .offset(x: movesContent ? dragX : 0)
            .rotationEffect(.degrees(movesContent ? Double(dragX / 40) : 0))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        let dx = value.translation.width
                        guard abs(dx) > abs(value.translation.height) * 1.3 else { return }
                        let limit = Self.threshold * 1.6
                        dragX = abs(dx) < limit ? dx : (dx > 0 ? 1 : -1) * (limit + (abs(dx) - limit) * 0.25)
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let horizontal = abs(dx) > abs(value.translation.height) * 1.3
                        let committed = horizontal && (abs(dx) > Self.threshold || abs(value.predictedEndTranslation.width) > 220)
                        if committed {
                            Haptics.impact(.light)
                            // The new card slides in on its own; drop the offset without animating back.
                            var reset = Transaction()
                            reset.disablesAnimations = true
                            withTransaction(reset) { dragX = 0 }
                            if dx < 0 {
                                player.next()
                            } else {
                                player.previous()
                            }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragX = 0 }
                        }
                    }
            )
            .accessibilityAction(named: "Next Song") { player.next() }
            .accessibilityAction(named: "Previous Song") { player.previous() }
    }
}
