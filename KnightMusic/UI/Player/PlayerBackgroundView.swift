import SwiftUI

/// Background view for FullPlayerView: plays full-bleed animated artwork if available,
/// or an organic, animated multi-gradient derived from `ArtworkPalette`.
/// Crossfades smoothly on song change.
struct PlayerBackgroundView: View {
    let song: Song?
    var isTall: Bool = true

    @Environment(AnimatedArtworkService.self) private var artworkService: AnimatedArtworkService?
    @State private var animatedArtwork: AnimatedArtwork?
    @State private var palette: ArtworkPalette = .fallback

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let animated = animatedArtwork {
                let videoURL = isTall ? (animated.tallVideoURL ?? animated.squareVideoURL) : animated.squareVideoURL
                AnimatedArtworkView(url: videoURL)
                    .id(videoURL)
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))

                // Dark gradient overlay at the bottom third for legibility
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.45),
                        .init(color: Color.black.opacity(0.55), location: 0.72),
                        .init(color: Color.black.opacity(0.92), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            } else {
                PaletteMeshBackground(palette: palette)
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
            }
        }
        .task(id: song?.id) {
            guard let song else {
                animatedArtwork = nil
                palette = .fallback
                return
            }
            async let artTask = artworkService?.animatedArtwork(for: song)
            async let palTask = ArtworkPalette.palette(for: song.coverArt)
            let (art, pal) = await (artTask, palTask)
            withAnimation(.easeInOut(duration: 0.8)) {
                animatedArtwork = art
                palette = pal
            }
        }
    }
}

/// Dynamic, softly moving organic gradient built from extracted palette colors.
private struct PaletteMeshBackground: View {
    let palette: ArtworkPalette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate * 0.18
            let shift1 = sin(time) * 0.18
            let shift2 = cos(time * 0.85) * 0.18

            ZStack {
                Color.black.ignoresSafeArea()

                // Primary ambient wash
                RadialGradient(
                    colors: [palette.primary.opacity(0.85), Color.black],
                    center: UnitPoint(x: 0.5 + shift1, y: 0.3 + shift2),
                    startRadius: 60,
                    endRadius: 680
                )
                .ignoresSafeArea()

                // Secondary color accent
                if let secColor = palette.swiftUIColors.dropFirst().first {
                    RadialGradient(
                        colors: [secColor.opacity(0.65), .clear],
                        center: UnitPoint(x: 0.75 - shift2, y: 0.65 - shift1),
                        startRadius: 50,
                        endRadius: 560
                    )
                    .blur(radius: 50)
                    .ignoresSafeArea()
                }

                // Tertiary color accent
                if let tertColor = palette.swiftUIColors.dropFirst(2).first {
                    RadialGradient(
                        colors: [tertColor.opacity(0.45), .clear],
                        center: UnitPoint(x: 0.25 + shift2, y: 0.7 + shift1),
                        startRadius: 40,
                        endRadius: 460
                    )
                    .blur(radius: 60)
                    .ignoresSafeArea()
                }

                // Subtle mesh overlay for rich depth
                palette.backgroundGradient
                    .opacity(0.5)
                    .ignoresSafeArea()

                // Bottom dark gradient for text legibility
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.45),
                        .init(color: Color.black.opacity(0.6), location: 0.72),
                        .init(color: Color.black.opacity(0.95), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }
}
