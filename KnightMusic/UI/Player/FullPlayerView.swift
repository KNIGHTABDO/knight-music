import SwiftUI

/// Full-screen player presented by the shell:
/// - Hero background: Full-bleed animated artwork if available; dynamic ArtworkPalette gradient otherwise
/// - Interactive swipe-down and chevron dismiss with rubber-band physics
/// - iPhone portrait: Big square artwork (width - 48, 12pt radius, 85% scale when paused)
///   Panels: Artwork / Lyrics / Queue with matched geometry animation on the artwork thumbnail
/// - iPad / Landscape: Two-column layout with artwork card on the left and controls/panels on the right
/// - Custom Scrubber with buffered fraction track, haptic boundaries, format description, and elapsed/remaining
/// - Transport controls with symbol bounce effects and replace transitions
/// - System volume slider row (iPhone only)
/// - Floating glass bottom bar (GlassEffectContainer) with circular glass controls
struct FullPlayerView: View {
    @Environment(UIState.self) private var ui
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library
    @Environment(AnimatedArtworkService.self) private var artworkService: AnimatedArtworkService?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @Namespace private var playerNamespace
    @State private var dragOffset: CGFloat = 0
    @State private var currentRating: Int = 0
    @State private var animatedArtwork: AnimatedArtwork?
    @State private var isShowingSettings = false

    private var hasAnimatedArtwork: Bool {
        animatedArtwork != nil
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let isTwoColumn = (hSizeClass == .regular) || isLandscape

            ZStack {
                if let song = player.currentSong {
                    // Full-bleed animated artwork or organic palette background
                    PlayerBackgroundView(song: song, isTall: !isTwoColumn)
                        .ignoresSafeArea()

                    // Main player content
                    VStack(spacing: 0) {
                        // Top drag grabber indicator
                        grabberHandle
                            .gesture(dismissDragGesture)

                        if isTwoColumn {
                            twoColumnLayout(song: song, geo: geo)
                        } else {
                            singleColumnLayout(song: song, geo: geo)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                } else {
                    emptyPlayerView
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: max(0, dragOffset))
            // Apply full-screen dismiss gesture when in artwork mode
            .gesture(ui.playerPanel == .artwork ? dismissDragGesture : nil)
            .sheet(isPresented: $isShowingSettings) {
                PlaybackSettingsSheet()
            }
            .task(id: player.currentSong?.id) {
                if let song = player.currentSong {
                    currentRating = song.userRating ?? 0
                    let art = await artworkService?.animatedArtwork(for: song)
                    withAnimation(.easeInOut(duration: 0.35)) {
                        animatedArtwork = art
                    }
                } else {
                    animatedArtwork = nil
                }
            }
            .onChange(of: currentRating) { _, newRating in
                guard let song = player.currentSong else { return }
                Task {
                    try? await library.setRating(.song, id: song.id, rating: newRating)
                }
            }
        }
    }

    // MARK: - Dismiss gesture

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                } else {
                    dragOffset = value.translation.height * 0.15
                }
            }
            .onEnded { value in
                let shouldDismiss = value.translation.height > 120 || value.predictedEndTranslation.height > 350
                if shouldDismiss {
                    withAnimation(.smooth(duration: 0.3)) {
                        ui.isPlayerPresented = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Grabber Handle

    private var grabberHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.32))
            .frame(width: 36, height: 5)
            .padding(.vertical, 8)
            .contentShape(Rectangle().inset(by: -10))
            .accessibilityHidden(true)
    }

    // MARK: - iPhone Portrait (Single Column)

    @ViewBuilder
    private func singleColumnLayout(song: Song, geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            switch ui.playerPanel {
            case .artwork:
                artworkPanel(song: song, geo: geo)

            case .lyrics:
                panelTopHeader(song: song)
                LyricsView(song: song)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .queue:
                panelTopHeader(song: song)
                QueueView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Fixed bottom player controls (Scrubber + Transport + Volume + Bottom Bar)
            VStack(spacing: 16) {
                PlayerScrubberView()
                    .padding(.horizontal, Theme.margin)

                PlayerTransportBar()

                PlayerVolumeRow()

                PlayerBottomBar(isShowingSettings: $isShowingSettings)
                    .padding(.bottom, 6)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Artwork Panel (iPhone)

    @ViewBuilder
    private func artworkPanel(song: Song, geo: GeometryProxy) -> some View {
        let artworkSize = min(geo.size.width - 48, geo.size.height * 0.42)

        VStack(spacing: 14) {
            Spacer(minLength: 8)

            // When NO animated artwork: big square artwork (width - 48, 12pt radius, scales to 85% when paused)
            // With animated artwork full-bleed: video plays in background, no separate square artwork
            if !hasAnimatedArtwork {
                ArtworkView(coverArt: song.coverArt, pointSize: artworkSize, cornerRadius: 12)
                    .matchedGeometryEffect(id: "albumArtwork", in: playerNamespace)
                    .frame(width: artworkSize, height: artworkSize)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.85)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
                    .shadow(color: .black.opacity(0.38), radius: 24, x: 0, y: 12)
            } else {
                Color.clear
                    .frame(width: artworkSize, height: artworkSize)
                    .matchedGeometryEffect(id: "albumArtwork", in: playerNamespace)
            }

            Spacer(minLength: 8)

            // Song Title & Artist
            VStack(spacing: 4) {
                Text(song.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(song.artist ?? "")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Theme.margin + 4)

            // Song actions row: Heart toggle · 5-star rating · ••• context menu
            HStack {
                Button {
                    Haptics.impact(.medium)
                    player.toggleStarCurrent()
                } label: {
                    Image(systemName: song.starred != nil ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundStyle(song.starred != nil ? Theme.accent : Theme.secondaryLabel)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(song.starred != nil ? "Unfavorite" : "Favorite")

                Spacer()

                StarRatingView(rating: $currentRating, starSize: 18, spacing: 6)

                Spacer()

                Menu {
                    SongActionsMenu(song: song)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Song Actions")
            }
            .padding(.horizontal, Theme.margin + 4)
        }
    }

    // MARK: - Panel Top Header (Lyrics / Queue on iPhone)

    @ViewBuilder
    private func panelTopHeader(song: Song) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: song.coverArt, pointSize: 56, cornerRadius: 8)
                .matchedGeometryEffect(id: "albumArtwork", in: playerNamespace)
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                Text(song.artist ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Haptics.impact(.medium)
                player.toggleStarCurrent()
            } label: {
                Image(systemName: song.starred != nil ? "heart.fill" : "heart")
                    .font(.system(size: 19))
                    .foregroundStyle(song.starred != nil ? Theme.accent : Theme.secondaryLabel)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                SongActionsMenu(song: song)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, 8)
    }

    // MARK: - iPad / Landscape (Two Columns)

    @ViewBuilder
    private func twoColumnLayout(song: Song, geo: GeometryProxy) -> some View {
        let side = min(geo.size.width * 0.42, geo.size.height * 0.72)

        HStack(spacing: 48) {
            // Left Column: Artwork (or Lyrics/Queue panel when active)
            Group {
                switch ui.playerPanel {
                case .artwork:
                    VStack {
                        Spacer()

                        if let animated = animatedArtwork {
                            AnimatedArtworkView(url: animated.squareVideoURL)
                                .frame(width: side, height: side)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.4), radius: 28, x: 0, y: 14)
                        } else {
                            ArtworkView(coverArt: song.coverArt, pointSize: side, cornerRadius: 12)
                                .frame(width: side, height: side)
                                .scaleEffect(player.isPlaying ? 1.0 : 0.85)
                                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
                                .shadow(color: .black.opacity(0.4), radius: 28, x: 0, y: 14)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)

                case .lyrics:
                    LyricsView(song: song)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .queue:
                    QueueView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Right Column: Controls Column (Vertically centered, max width 480)
            VStack(spacing: 28) {
                // Header row: title/artist + heart/stars/••• (plus shrunk artwork thumbnail if panel is open)
                HStack(alignment: .center, spacing: 14) {
                    if ui.playerPanel != .artwork {
                        ArtworkView(coverArt: song.coverArt, pointSize: 56, cornerRadius: 8)
                            .frame(width: 56, height: 56)
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                            .font(.system(size: ui.playerPanel == .artwork ? 24 : 20, weight: .bold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)

                        Text(song.artist ?? "")
                            .font(.system(size: ui.playerPanel == .artwork ? 18 : 15))
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        Haptics.impact(.medium)
                        player.toggleStarCurrent()
                    } label: {
                        Image(systemName: song.starred != nil ? "heart.fill" : "heart")
                            .font(.system(size: 20))
                            .foregroundStyle(song.starred != nil ? Theme.accent : Theme.secondaryLabel)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    StarRatingView(rating: $currentRating, starSize: 18, spacing: 5)

                    Menu {
                        SongActionsMenu(song: song)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.secondaryLabel)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                }

                PlayerScrubberView()

                PlayerTransportBar()

                PlayerVolumeRow()

                PlayerBottomBar(isShowingSettings: $isShowingSettings)
            }
            .frame(maxWidth: 480)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(.horizontal, 56)
    }

    // MARK: - Empty State View

    private var emptyPlayerView: some View {
        VStack(spacing: 24) {
            grabberHandle

            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(Theme.tertiaryLabel)

            Text("Not Playing")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.white)

            Text("Select a song from your library to start playing.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                withAnimation(.smooth) {
                    ui.isPlayerPresented = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
    }
}
