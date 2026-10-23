import SwiftUI

/// Background view for FullPlayerView: plays full-bleed animated artwork if available,
/// or an organic, animated multi-gradient derived from `ArtworkPalette`.
/// Crossfades smoothly on song change.
struct PlayerBackgroundView: View {
    let song: Song?
    var isTall: Bool = true

    init(song: Song?, isTall: Bool = true) {
        self.song = song
        self.isTall = isTall
        _palette = State(initialValue: ArtworkPalette.cachedPalette(for: song?.coverArt) ?? .fallback)
    }

    @Environment(AnimatedArtworkService.self) private var artworkService: AnimatedArtworkService?
    @State private var animatedArtwork: AnimatedArtwork?
    @State private var animatedAlbumId: String?
    @State private var palette: ArtworkPalette

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let animated = animatedArtwork {
                let videoURL = isTall ? (animated.tallVideoURL ?? animated.squareVideoURL) : animated.squareVideoURL
                // AVPlayerLayer already aspect-fills; a SwiftUI .fill here makes the 3:4 video
                // report a size wider than the phone and drags the whole player layout off-screen.
                AnimatedArtworkView(url: videoURL)
                    .id(videoURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: song?.id) {
            guard let song else {
                animatedArtwork = nil
                palette = .fallback
                return
            }
            if song.albumId != animatedAlbumId {
                withAnimation(.easeInOut(duration: 0.5)) { animatedArtwork = nil }
                animatedAlbumId = song.albumId
            }
            // The palette is quick and the clip may still be downloading: show the palette first.
            let pal = await ArtworkPalette.palette(for: song.coverArt)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { palette = pal }
            let art = await artworkService?.animatedArtwork(for: song)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { animatedArtwork = art }
        }
    }
}

/// Softly moving mesh gradient built from the palette. GPU-cheap; animates only while playing.
private struct PaletteMeshBackground: View {
    let palette: ArtworkPalette

    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying || reduceMotion)) { timeline in
            let t = Float(timeline.date.timeIntervalSinceReferenceDate * 0.22)
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.points(at: t),
                colors: meshColors,
                smoothsColors: true
            )
            .ignoresSafeArea()
        }
        .overlay {
            // Bottom fade keeps the controls legible over bright palettes.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.45),
                    .init(color: Color.black.opacity(0.55), location: 0.75),
                    .init(color: Color.black.opacity(0.9), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.8), value: palette)
    }

    private var meshColors: [Color] {
        let c = palette.swiftUIColors
        func pick(_ i: Int) -> Color { c.isEmpty ? .black : c[i % c.count] }
        return [
            pick(0), pick(1), pick(0),
            pick(2), pick(0), pick(1),
            pick(1).opacity(0.7), pick(2).opacity(0.6), pick(0).opacity(0.7)
        ].map { $0.mix(with: .black, by: 0.15) }
    }

    /// Edge points stay pinned to the frame; the interior and edge midpoints drift on slow sine curves.
    private static func points(at t: Float) -> [SIMD2<Float>] {
        [
            [0, 0], [0.5 + 0.12 * sin(t), 0], [1, 0],
            [0, 0.5 + 0.1 * cos(t * 0.9)], [0.5 + 0.15 * sin(t * 0.7), 0.5 + 0.12 * cos(t * 0.8)], [1, 0.5 + 0.1 * sin(t * 1.1)],
            [0, 1], [0.5 + 0.12 * cos(t * 0.6), 1], [1, 1]
        ]
    }
}
