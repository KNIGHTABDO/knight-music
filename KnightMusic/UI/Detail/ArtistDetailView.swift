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
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var artistInfo: ArtistInfo?
    @State private var isBioExpanded = false

    var body: some View {
        let artistQuery = library.artist(id: artistId)
        let topSongsQuery = library.topSongs(artistId: artistId)
        let albumsQuery = library.albums(artistId: artistId)
        let allSongsQuery = library.songs(artistId: artistId)
        let allArtistsQuery = library.artists()

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
                    message: "This artist is not available in your library.",
                    actionTitle: "Sync Now",
                    action: { Task { await app.pullToRefresh() } }
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
        let byRelease = albums.sorted { Self.releaseKey($0) > Self.releaseKey($1) }
        let fullAlbums = byRelease.filter { ($0.songCount ?? 0) > 3 }
        let singles = byRelease.filter { ($0.songCount ?? 0) <= 3 }

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroHeaderView(artist: artist, topSongs: topSongs, allSongs: allSongs)

                VStack(alignment: .leading, spacing: 28) {
                    if sizeClass == .regular, let latest = byRelease.first {
                        // iPad: Latest Release beside Top Songs, as in Apple Music
                        HStack(alignment: .top, spacing: 28) {
                            latestReleaseCard(latest)
                                .frame(width: 300)
                            if !topSongs.isEmpty {
                                topSongsSection(topSongs: topSongs, artistName: artist.name)
                            }
                        }
                        .padding(.leading, Theme.margin)
                    } else {
                        if let latest = byRelease.first {
                            latestReleaseCard(latest)
                                .padding(.horizontal, Theme.margin)
                        }
                        if !topSongs.isEmpty {
                            topSongsSection(topSongs: topSongs, artistName: artist.name)
                        }
                    }

                    if !fullAlbums.isEmpty {
                        albumShelf("Albums", fullAlbums)
                    }
                    if !singles.isEmpty {
                        albumShelf("Singles & EPs", singles)
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
                .padding(.top, 20)
                .background(Theme.background)
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            toolbarItems(artist: artist, allSongs: allSongs)
        }
    }

    // MARK: - Hero Header

    private var heroHeight: CGFloat { sizeClass == .regular ? 460 : 400 }

    /// Stretches when pulled down, drifts at half speed when scrolled up (parallax).
    private func heroHeaderView(artist: Artist, topSongs: [Song], allSongs: [Song]) -> some View {
        let height = heroHeight
        return GeometryReader { geo in
            let minY = geo.frame(in: .scrollView).minY
            ZStack(alignment: .bottomLeading) {
                heroImage(artist: artist, width: geo.size.width)
                    .frame(width: geo.size.width, height: height + max(0, minY))
                    .clipped()
                    .offset(y: minY > 0 ? -minY : -minY * 0.5)

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
                .frame(height: 200)

                HStack(alignment: .bottom, spacing: 14) {
                    Text(artist.name)
                        .font(.system(size: sizeClass == .regular ? 44 : 34, weight: .heavy))
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
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
                    .accessibilityLabel("Play \(artist.name)")
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 16)
            }
            .frame(width: geo.size.width, height: height, alignment: .bottom)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func heroImage(artist: Artist, width: CGFloat) -> some View {
        if let imageUrl = artistInfo?.largeImageUrl, let url = URL(string: imageUrl) {
            LazyImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ArtworkView(coverArt: artist.coverArt, pointSize: width, cornerRadius: 0, placeholderSymbol: "person.fill")
                        .scaledToFill()
                }
            }
        } else {
            ArtworkView(coverArt: artist.coverArt, pointSize: width, cornerRadius: 0, placeholderSymbol: "person.fill")
        }
    }

    // MARK: - Latest Release & Albums

    /// Newest release first: tagged release date, then year, then when it was added.
    private static func releaseKey(_ album: Album) -> String {
        let release = album.releaseDate
        let year = release?.year ?? album.year ?? 0
        let date = String(format: "%04d-%02d-%02d", year, release?.month ?? 0, release?.day ?? 0)
        return date + (album.created?.ISO8601Format() ?? "")
    }

    private func latestReleaseCard(_ album: Album) -> some View {
        NavigationLink(value: Route.album(album.id)) {
            HStack(spacing: 14) {
                ArtworkView(coverArt: album.coverArt, pointSize: 96)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LATEST RELEASE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryLabel)
                    if let when = latestReleaseDate(album) {
                        Text(when)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    Text(album.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                    if let count = album.songCount {
                        Text(KMFormat.songCount(count))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { AlbumContextMenu(album: album) }
    }

    private func latestReleaseDate(_ album: Album) -> String? {
        if let release = album.releaseDate, let date = release.date, release.month != nil, release.day != nil {
            return date.formatted(date: .abbreviated, time: .omitted).uppercased()
        }
        return album.year.map(String.init)
    }

    private func albumShelf(_ title: String, _ albums: [Album]) -> some View {
        ShelfSection(title: title, items: albums) { album in
            NavigationLink(value: Route.album(album.id)) {
                AlbumTile(coverArt: album.coverArt, title: album.name, subtitle: album.year.map(String.init))
            }
            .buttonStyle(.plain)
            .contextMenu { AlbumContextMenu(album: album) }
        }
        .scrollClipDisabled()
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
                    try? await library.toggleStar(.artist, id: artist.id, currentlyStarred: isStarred)
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

                if let seed = allSongs.randomElement() {
                    Button {
                        Task { await player.startStation(from: seed) }
                    } label: {
                        Label("Start Station", systemImage: "dot.radiowaves.left.and.right")
                    }
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
