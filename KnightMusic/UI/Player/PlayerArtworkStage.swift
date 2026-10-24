import SwiftUI

/// The player's artwork (card, circle or spinning vinyl per the look): shrinks when paused, follows a horizontal swipe and skips past a
/// threshold, and slides the next cover in from the side it came from.
struct PlayerArtworkStage: View {
    let song: Song
    let side: CGFloat
    var animatedVideoURL: URL?

    @Environment(PlayerEngine.self) private var player
    @Environment(LookStore.self) private var looks
    @State private var shownSongId: String?

    var body: some View {
        let look = looks.current
        let shrinks = look.shrinkWhenPaused && look.artworkShape == .card
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
        .modifier(ArtworkPulse(mode: look.pulse, bpm: song.bpm))
        .scaleEffect(player.isPlaying || !shrinks ? 1.0 : 0.85)
        .shadow(color: glowColor(look), radius: player.isPlaying ? 42 : 24)
        .shadow(color: .black.opacity(player.isPlaying ? 0.4 : 0.25), radius: player.isPlaying ? 28 : 16, x: 0, y: player.isPlaying ? 14 : 8)
        .animation(.smooth(duration: 0.5), value: look.artworkShape)
        .animation(.smooth(duration: 0.3), value: look.artworkRadius)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: song.id)
        .modifier(SkipSwipeModifier(movesContent: true))
        .onChange(of: song.id, initial: true) { _, newId in
            shownSongId = newId
        }
    }

    private func glowColor(_ look: Look) -> Color {
        guard look.artworkGlow else { return .clear }
        return (looks.artworkColors.first ?? Theme.accent).opacity(player.isPlaying ? 0.75 : 0.4)
    }

    @ViewBuilder
    private var card: some View {
        let look = looks.current
        switch look.artworkShape {
        case .card:
            cover(radius: look.artworkRadius, size: side)
        case .circle:
            cover(radius: nil, size: side)
        case .vinyl:
            VinylRecord(side: side) { cover(radius: nil, size: VinylRecord<EmptyView>.labelSide(for: side)) }
        }
    }

    /// The cover (or its animated clip): rounded rectangle, or a circle when `radius` is nil.
    @ViewBuilder
    private func cover(radius: Double?, size: CGFloat) -> some View {
        let shape = radius.map { AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous)) } ?? AnyShape(Circle())
        if let animatedVideoURL {
            AnimatedArtworkView(url: animatedVideoURL)
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            ArtworkView(coverArt: song.coverArt, pointSize: size, cornerRadius: radius ?? 0, isCircle: false)
                .frame(width: size, height: size)
                .clipShape(shape)
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
