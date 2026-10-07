import SwiftUI
import NukeUI

/// Artist detail screen matching Apple Music / Arpeggi.
struct ArtistDetailView: View {
    let artistId: String

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui
    @Environment(HermesService.self) private var hermes: HermesService?
    @Environment(\.colorScheme) private var colorScheme

    @State private var artistInfo: ArtistInfo?
    @State private var isBioExpanded = false

    var body: some View {
        let artistQuery = library.artist(id: artistId)
        let topSongsQuery = library.topSongs(artistId: artistId)
        let albumsQuery = library.albums(artistId: artistId)
        let allSongsQuery = library.songs(artistId: artistId)
        let allArtistsQuery = library.artists()
        let playlists = library.playlists()

        Group {
            if !artistQuery.isLoaded {
                skeletonView
            } else if let artist = artistQuery.value {
                artistContentView(
                    artist: artist,
                    topSongs: topSongsQuery.value,
                    albums: albumsQuery.value,
                    allSongs: allSongsQuery.value,
                    allArtists: allArtistsQuery.value
                )
            } else {
                EmptyStateView(
                    title: "Artist Not Found",
                    systemImage: "person.crop.circle",
                    message: "This artist is not available in your library."
                )
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await app.pullToRefresh() }
        .task(id: artistId) {
            artistInfo = await library.artistInfo(artistId: artistId)
        }
        .observing(artistQuery)
        .observing(topSongsQuery)
        .observing(albumsQuery)
        .observing(allSongsQuery)
        .observing(allArtistsQuery)
        .observing(playlists)
    }

    // MARK: - Artist Content

    private func artistContentView(
        artist: Artist,
        topSongs: [Song],
        albums: [Album],
        allSongs: [Song],
        allArtists: [Artist]
    ) -> some View {
        let localArtistsById = Dictionary(allArtists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let similarArtists = (artistInfo?.similarArtist ?? []).compactMap { localArtistsById[$0.id] }

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Full-width hero image ~320pt tall with overlay
                heroHeaderView(artist: artist, topSongs: topSongs, allSongs: allSongs)

                // Top Songs section (first 5 rows with artwork, "See All" pushes full list)
                if !topSongs.isEmpty {
                    topSongsSection(topSongs: topSongs, artistName: artist.name)
                }

                // Albums (horizontal ShelfSection sorted newest first)
                if !albums.isEmpty {
                    ShelfSection(title: "Albums", items: albums) { album in
                        NavigationLink(value: Route.album(album.id)) {
                            AlbumTile(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                    .scrollClipDisabled()
                }

                // About section (biography from artistInfo, HTML stripped, 4 lines + "More")
                if let bio = artistInfo?.plainBiography, !bio.isEmpty {
                    aboutSection(bio: bio)
                }

                // Similar Artists (circular tiles of similar artists existing in local library)
                if !similarArtists.isEmpty {
                    similarArtistsSection(similarArtists: similarArtists)
                }

                Spacer().frame(height: 32)
            }
        }
        .toolbar {
            toolbarItems(artist: artist, allSongs: allSongs)
        }
    }

    // MARK: - Hero Header

    private func heroHeaderView(artist: Artist, topSongs: [Song], allSongs: [Song]) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Artist image
                Group {
                    if let imageUrl = artistInfo?.largeImageUrl, let url = URL(string: imageUrl) {
                        LazyImage(url: url) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                ArtworkView(
                                    coverArt: artist.coverArt,
                                    pointSize: geo.size.width,
                                    placeholderSymbol: "person.fill",
                                    fillsContainer: true
                                )
                            }
                        }
                    } else {
                        ArtworkView(
                            coverArt: artist.coverArt,
                            pointSize: geo.size.width,
                            placeholderSymbol: "person.fill",
                            fillsContainer: true
                        )
                    }
                }
                .frame(width: geo.size.width, height: 320)
                .clipped()

                // Gradient fade to background at the bottom
                LinearGradient(
                    colors: [
                        Color.clear,
                        Theme.background.opacity(0.35),
                        Theme.background.opacity(0.85),
                        Theme.background
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // Overlaid artist name bottom-left, play button bottom-right
                HStack(alignment: .bottom, spacing: 14) {
                    Text(artist.name)
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                        .shadow(color: colorScheme == .dark ? .black.opacity(0.7) : .clear, radius: 6, y: 3)

                    Spacer(minLength: 8)

                    Button {
                        Haptics.impact(.medium)
                        let songsToPlay = !topSongs.isEmpty ? topSongs : allSongs
                        if !songsToPlay.isEmpty {
                            player.play(songsToPlay, startAt: 0, shuffle: false)
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glassProminent)
                    .clipShape(Circle())
                    .tint(Theme.accent)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 16)
            }
        }
        .frame(height: 320)
    }

    // MARK: - Top Songs Section

    private func topSongsSection(topSongs: [Song], artistName: String) -> some View {
        let top5 = Array(topSongs.prefix(5))

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Top Songs")
                Spacer()
                if topSongs.count > 5 {
                    NavigationLink {
                        ArtistTopSongsView(artistName: artistName, songs: topSongs)
                    } label: {
                        Text("See All")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, Theme.margin)

            VStack(spacing: 0) {
                ForEach(Array(top5.enumerated()), id: \.element.id) { index, song in
                    let isPlaying = player.currentSong?.id == song.id
                    let isPaused = isPlaying && !player.isPlaying
                    let isDownloaded = downloads.isDownloaded(song.id)

                    Button {
                        Haptics.selection()
                        player.play(topSongs, startAt: index, shuffle: false)
                    } label: {
                        SongRow(
                            song: song,
                            showsArtwork: true,
                            isPlaying: isPlaying,
                            isPaused: isPaused,
                            isDownloaded: isDownloaded
                        ) {
                            SongActionsMenu(song: song)
                        }
                        .padding(.horizontal, Theme.margin)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        SongActionsMenu(song: song)
                    }

                    if index < top5.count - 1 {
                        Divider().padding(.leading, Theme.margin + 48 + 12)
                    }
                }
            }
        }
    }

    // MARK: - About Section

    private func aboutSection(bio: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "About")

            Text(bio)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryLabel)
                .lineLimit(isBioExpanded ? nil : 4)
                .animation(.smooth, value: isBioExpanded)

            Button {
                withAnimation(.smooth) {
                    isBioExpanded.toggle()
                }
            } label: {
                Text(isBioExpanded ? "Less" : "More")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - Similar Artists Section

    private func similarArtistsSection(similarArtists: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Similar Artists")
                .padding(.horizontal, Theme.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(similarArtists) { sim in
                        NavigationLink(value: Route.artist(sim.id)) {
                            VStack(spacing: 8) {
                                ArtworkView(coverArt: sim.coverArt, pointSize: 110, isCircle: true)
                                Text(sim.name)
                                    .font(.kmTileTitle)
                                    .foregroundStyle(Theme.label)
                                    .lineLimit(1)
                                    .frame(width: 110)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Theme.margin, for: .scrollContent)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarItems(artist: Artist, allSongs: [Song]) -> some ToolbarContent {
        let isStarred = artist.starred != nil

        ToolbarItemGroup(placement: .topBarTrailing) {
            // Heart button (favorite toggle)
            Button {
                Haptics.impact(.light)
                Task {
                    do {
                        try await library.toggleStar(.artist, id: artist.id, currentlyStarred: isStarred)
                    } catch {
                        Log.sync.error("Toggle star artist failed for \(artist.id): \(error)")
                    }
                }
            } label: {
                Image(systemName: isStarred ? "heart.fill" : "heart")
                    .foregroundStyle(isStarred ? Theme.accent : Theme.label)
            }

            // ••• Menu
            Menu {
                Button {
                    player.play(allSongs, shuffle: true)
                } label: {
                    Label("Shuffle All", systemImage: "shuffle")
                }

                Button {
                    player.enqueue(allSongs, next: true)
                    ui.showToast("Playing Next")
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    downloads.download(songs: allSongs)
                    ui.showToast("Downloading All Songs")
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle")
                }

                if hermes?.settings.isConfigured == true {
                    Divider()

                    Button {
                        ui.askKnight("Add more popular songs by \(artist.name) that I don't have yet")
                    } label: {
                        Label("Get more from \(artist.name)", systemImage: "sparkles")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    // MARK: - Skeleton View

    private var skeletonView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LoadingShimmer(cornerRadius: 0)
                    .frame(height: 320)

                SkeletonRowList(count: 5)
            }
        }
    }
}
