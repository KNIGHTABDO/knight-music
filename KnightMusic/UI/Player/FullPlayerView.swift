import SwiftUI

/// Full-screen player presented by the shell (zoom transition from the mini player; swipe-down
/// dismiss is the native interactive one of that transition):
/// - Hero background: full-bleed animated artwork if available, animated palette mesh otherwise
/// - iPhone portrait: big square artwork that shrinks when paused and swipes to change tracks;
///   panels Artwork / Lyrics / Queue
/// - iPad: big artwork beside the controls; lyrics and queue open beside the artwork
/// - Landscape iPhone: two columns, the left one switches between artwork and panels
/// - Lyrics: the controls fade away after a few idle seconds; a tap brings them back
struct FullPlayerView: View {
    @Environment(UIState.self) private var ui
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AnimatedArtworkService.self) private var artworkService: AnimatedArtworkService?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @Namespace private var playerNamespace
    @State private var currentRating: Int = 0
    @State private var animatedArtwork: AnimatedArtwork?
    @State private var animatedAlbumId: String?
    @State private var isShowingSettings = false
    @State private var controlsHidden = false
    @State private var controlsActivity = 0

    private var hasAnimatedArtwork: Bool {
        animatedArtwork != nil
    }

    /// Rating changes are written to the server only when the user taps a star.
    private var ratingBinding: Binding<Int> {
        Binding(
            get: { currentRating },
            set: { newRating in
                guard let song = player.currentSong, newRating != currentRating else { return }
                currentRating = newRating
                Task {
                    do {
                        try await library.setRating(.song, id: song.id, rating: newRating)
                    } catch {
                        Log.sync.error("Set rating failed for song \(song.id): \(error)")
                        ui.showToast("Couldn't save the rating")
                    }
                }
            }
        )
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let isRegular = hSizeClass == .regular

            Group {
                if let song = player.currentSong {
                    VStack(spacing: 0) {
                        grabberHandle

                        if isRegular {
                            regularLayout(song: song, geo: geo, isLandscape: isLandscape)
                        } else if isLandscape {
                            compactLandscapeLayout(song: song, geo: geo)
                        } else {
                            singleColumnLayout(song: song, geo: geo)
                        }
                    }
                    // geo is already inside the safe area; only add breathing room where there is no inset.
                    .padding(.top, geo.safeAreaInsets.top > 0 ? 0 : 16)
                    .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 0 : 12)
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Background (full-bleed video can be far wider than the phone) lives in
                    // .background so it can never resize the controls laid out on top of it.
                    .background {
                        ZStack {
                            PlayerBackgroundView(song: song, isTall: !isRegular && !isLandscape)

                            // Legibility veil for Lyrics and Queue so text stays crisp over bright covers
                            if ui.playerPanel != .artwork {
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                                    .overlay(Color.black.opacity(0.45))
                                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                            }
                        }
                        .ignoresSafeArea()
                    }
                } else {
                    emptyPlayerView
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { revealControls() })
            .sheet(isPresented: $isShowingSettings) {
                PlaybackSettingsSheet()
            }
            .task(id: player.currentSong?.id) {
                if let song = player.currentSong {
                    currentRating = song.userRating ?? 0
                    // A different album must not keep showing the previous clip while its own one loads.
                    if song.albumId != animatedAlbumId {
                        withAnimation(.easeInOut(duration: 0.35)) { animatedArtwork = nil }
                        animatedAlbumId = song.albumId
                    }
                    let art = await artworkService?.animatedArtwork(for: song)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        animatedArtwork = art
                    }
                } else {
                    animatedArtwork = nil
                }
            }
            .task(id: "\(controlsActivity)|\(ui.playerPanel == .lyrics)|\(player.isPlaying)") {
                await autoHideControls()
            }
        }
    }

    // MARK: - Auto-hiding controls (lyrics)

    private var shouldAutoHide: Bool {
        ui.playerPanel == .lyrics && player.isPlaying
    }

    private func revealControls() {
        controlsActivity += 1
        if controlsHidden {
            withAnimation(.smooth(duration: 0.3)) { controlsHidden = false }
        }
    }

    private func autoHideControls() async {
        guard shouldAutoHide else {
            if controlsHidden { withAnimation(.smooth(duration: 0.3)) { controlsHidden = false } }
            return
        }
        do { try await Task.sleep(for: .seconds(4)) } catch { return }
        guard shouldAutoHide else { return }
        withAnimation(.smooth(duration: 0.5)) { controlsHidden = true }
    }

    // MARK: - Grabber Handle

    private var grabberHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.32))
            .frame(width: 36, height: 5)
            .padding(.vertical, 8)
            .opacity(controlsHidden ? 0 : 1)
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
                if !controlsHidden {
                    panelTopHeader(song: song)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                LyricsView(song: song)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .queue:
                panelTopHeader(song: song)
                QueueView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !controlsHidden {
                VStack(spacing: 14) {
                    PlayerScrubberView()
                        .padding(.horizontal, Theme.margin + 4)

                    PlayerTransportBar()

                    if ui.playerPanel == .artwork {
                        PlayerVolumeRow()
                    }

                    PlayerBottomBar(isShowingSettings: $isShowingSettings)
                        .padding(.bottom, 4)
                }
                .padding(.top, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Artwork Panel (iPhone)

    @ViewBuilder
    private func artworkPanel(song: Song, geo: GeometryProxy) -> some View {
        let artworkSize = min(geo.size.width - 48, geo.size.height * 0.40)

        VStack(spacing: 14) {
            if !hasAnimatedArtwork {
                Spacer(minLength: 8)

                PlayerArtworkStage(song: song, side: artworkSize)
                    .matchedGeometryEffect(id: "albumArtwork", in: playerNamespace)

                Spacer(minLength: 8)
            } else {
                // The full-bleed video shows through the upper half; it still swipes to change tracks.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(SkipSwipeModifier(movesContent: false))
                    .overlay(alignment: .bottom) {
                        // Anchor for the matched geometry transition to the panel header.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .matchedGeometryEffect(id: "albumArtwork", in: playerNamespace)
                    }
            }

            PlayerSongTitles(song: song)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.margin + 4)

            PlayerSongActionsRow(song: song, rating: ratingBinding, showsRating: settings.showRatings)
                .padding(.horizontal, Theme.margin + 4)
        }
    }

    // MARK: - Panel Top Header (Lyrics / Queue on iPhone)

    @ViewBuilder
    private func panelTopHeader(song: Song) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: song.coverArt, pointSize: 52, cornerRadius: 8)
                .matchedGeometryEffect(id: "albumArtwork", in: playerNamespace)
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            PlayerSongTitles(song: song, titleSize: 17, artistSize: 14)

            Spacer(minLength: 4)

            PlayerSongActionsRow(song: song, rating: ratingBinding, showsRating: false)
                .fixedSize()
        }
        .padding(.horizontal, Theme.margin + 4)
        .padding(.vertical, 8)
    }

    // MARK: - iPad

    /// Artwork panel: huge artwork on the left, controls on the right.
    /// Lyrics / Queue: artwork and controls stack on the left, the panel takes the right half.
    @ViewBuilder
    private func regularLayout(song: Song, geo: GeometryProxy, isLandscape: Bool) -> some View {
        let horizontalPadding: CGFloat = isLandscape ? 64 : 48

        if ui.playerPanel == .artwork {
            if isLandscape {
                let side = min(geo.size.width * 0.46, geo.size.height * 0.78)
                HStack(spacing: 64) {
                    PlayerArtworkStage(song: song, side: side, animatedVideoURL: animatedArtwork?.squareVideoURL)
                        .frame(maxWidth: .infinity)

                    regularControls(song: song, titleSize: 28, artistSize: 20)
                        .frame(maxWidth: 520)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .padding(.horizontal, horizontalPadding)
            } else {
                // iPad portrait: artwork on top, wide controls underneath (Apple Music layout).
                let side = min(geo.size.width - horizontalPadding * 2, geo.size.height * 0.5)
                VStack(spacing: 36) {
                    Spacer(minLength: 12)
                    PlayerArtworkStage(song: song, side: side, animatedVideoURL: animatedArtwork?.squareVideoURL)
                    Spacer(minLength: 12)
                    regularControls(song: song, titleSize: 28, artistSize: 20)
                        .frame(maxWidth: 640)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 12)
            }
        } else {
            let side = min(geo.size.width * 0.3, geo.size.height * 0.36)
            HStack(alignment: .center, spacing: 48) {
                if !controlsHidden {
                    VStack(spacing: 24) {
                        Spacer(minLength: 0)
                        PlayerArtworkStage(song: song, side: side, animatedVideoURL: animatedArtwork?.squareVideoURL)
                        regularControls(song: song, titleSize: 22, artistSize: 17)
                        Spacer(minLength: 0)
                    }
                    .frame(width: max(side, min(geo.size.width * 0.4, 440)))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Group {
                    if ui.playerPanel == .lyrics {
                        LyricsView(song: song)
                    } else {
                        QueueView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, horizontalPadding)
        }
    }

    private func regularControls(song: Song, titleSize: CGFloat, artistSize: CGFloat) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                PlayerSongTitles(song: song, titleSize: titleSize, artistSize: artistSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlayerSongActionsRow(song: song, rating: ratingBinding, starSize: 20, showsRating: settings.showRatings)
            }

            PlayerScrubberView()

            PlayerTransportBar()

            PlayerVolumeRow()

            PlayerBottomBar(isShowingSettings: $isShowingSettings)
        }
    }

    // MARK: - Landscape iPhone (Two Columns)

    @ViewBuilder
    private func compactLandscapeLayout(song: Song, geo: GeometryProxy) -> some View {
        let side = min(geo.size.width * 0.42, geo.size.height * 0.72)

        HStack(spacing: 40) {
            Group {
                switch ui.playerPanel {
                case .artwork:
                    PlayerArtworkStage(song: song, side: side, animatedVideoURL: animatedArtwork?.squareVideoURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .lyrics:
                    LyricsView(song: song)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .queue:
                    QueueView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    if ui.playerPanel != .artwork {
                        ArtworkView(coverArt: song.coverArt, pointSize: 52, cornerRadius: 8)
                            .frame(width: 52, height: 52)
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }
                    PlayerSongTitles(song: song, titleSize: 20, artistSize: 15)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PlayerSongActionsRow(song: song, rating: ratingBinding, showsRating: settings.showRatings)

                PlayerScrubberView()

                PlayerTransportBar()

                PlayerBottomBar(isShowingSettings: $isShowingSettings)
            }
            .frame(maxWidth: 440)
            .frame(maxHeight: .infinity, alignment: .center)
            .opacity(controlsHidden ? 0 : 1)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Empty State View

    private var emptyPlayerView: some View {
        VStack(spacing: 24) {
            grabberHandle

            ContentUnavailableView {
                Label("Not Playing", systemImage: "music.note")
            } description: {
                Text("Pick a song from your library to start playing.")
            }
            .frame(maxHeight: .infinity)

            Button {
                ui.isPlayerPresented = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close Player")
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
    }
}
