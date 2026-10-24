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
    @Environment(LookStore.self) private var looks

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
                backdrop
                    .overlay { LegibilityFade() }
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.6), value: looks.current.backdrop)
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

extension PlayerBackgroundView {
    @ViewBuilder
    fileprivate var backdrop: some View {
        switch looks.current.backdrop {
        case .palette:
            PaletteMeshBackground(palette: palette, aurora: false)
        case .aurora:
            PaletteMeshBackground(palette: palette, aurora: true)
        case .blurredArtwork:
            BlurredCoverBackground(coverArt: song?.coverArt)
        case .spotlight:
            SpotlightBackground(palette: palette)
        case .black:
            Color.black.ignoresSafeArea()
        }
    }
}

/// Bottom fade that keeps the controls legible over bright backgrounds.
private struct LegibilityFade: View {
    var body: some View {
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
        .allowsHitTesting(false)
    }
}

/// The cover itself, hugely enlarged and blurred, slowly turning while music plays.
private struct BlurredCoverBackground: View {
    let coverArt: String?

    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 1.5
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !player.isPlaying || reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ArtworkView(coverArt: coverArt, pointSize: 160, cornerRadius: 0)
                    .scaleEffect(side / 160)
                    .rotationEffect(.degrees(reduceMotion ? 0 : (t * 3).truncatingRemainder(dividingBy: 360)))
                    .blur(radius: 70)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .overlay(Color.black.opacity(0.28))
        }
        .clipped()
        .ignoresSafeArea()
        .id(coverArt)
        .transition(.opacity)
    }
}

/// A stage light: the cover's main color falls from the top onto black, its second color glows below.
private struct SpotlightBackground: View {
    let palette: ArtworkPalette

    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let colors = palette.swiftUIColors
            let main = colors.first ?? .gray
            let second = colors.count > 1 ? colors[1] : main
            GeometryReader { geo in
                ZStack {
                    Color.black
                    RadialGradient(
                        colors: [main.opacity(0.95), main.opacity(0.35), .clear],
                        center: UnitPoint(x: 0.5 + 0.08 * sin(t * 0.4), y: -0.05),
                        startRadius: 0,
                        endRadius: geo.size.height * (0.75 + 0.04 * sin(t * 0.9))
                    )
                    RadialGradient(
                        colors: [second.opacity(0.45), .clear],
                        center: UnitPoint(x: 0.5 - 0.1 * cos(t * 0.3), y: 1.05),
                        startRadius: 0,
                        endRadius: geo.size.height * 0.55
                    )
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: palette)
    }
}

/// Softly moving mesh gradient built from the palette. GPU-cheap; animates only while playing.
/// Aurora: faster, brighter, shifts hue and weaves the accent color in.
private struct PaletteMeshBackground: View {
    let palette: ArtworkPalette
    var aurora: Bool

    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let t = Float(time * (aurora ? 0.5 : 0.22))
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.points(at: t, amplitude: aurora ? 1.6 : 1),
                colors: meshColors,
                smoothsColors: true
            )
            .hueRotation(.degrees(aurora ? 30 * sin(time * 0.15) : 0))
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.8), value: palette)
    }

    private var meshColors: [Color] {
        var c = palette.swiftUIColors
        if aurora { c.insert(Theme.accent, at: 1) }
        func pick(_ i: Int) -> Color { c.isEmpty ? .black : c[i % c.count] }
        let colors = [
            pick(0), pick(1), pick(0),
            pick(2), pick(0), pick(1),
            pick(1).opacity(0.7), pick(2).opacity(0.6), pick(0).opacity(0.7)
        ]
        return aurora ? colors.map { $0.mix(with: .black, by: 0.05) } : colors.map { $0.mix(with: .black, by: 0.15) }
    }

    /// Edge points stay pinned to the frame; the interior and edge midpoints drift on slow sine curves.
    private static func points(at t: Float, amplitude a: Float) -> [SIMD2<Float>] {
        let top: Float = 0.5 + 0.12 * a * sin(t)
        let left: Float = 0.5 + 0.1 * a * cos(t * 0.9)
        let midX: Float = 0.5 + 0.15 * a * sin(t * 0.7)
        let midY: Float = 0.5 + 0.12 * a * cos(t * 0.8)
        let right: Float = 0.5 + 0.1 * a * sin(t * 1.1)
        let bottom: Float = 0.5 + 0.12 * a * cos(t * 0.6)
        return [
            SIMD2(0, 0), SIMD2(top, 0), SIMD2(1, 0),
            SIMD2(0, left), SIMD2(midX, midY), SIMD2(1, right),
            SIMD2(0, 1), SIMD2(bottom, 1), SIMD2(1, 1)
        ]
    }
}
