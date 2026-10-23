import SwiftUI
import GRDB

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui: UIState?
    @Environment(HermesService.self) private var hermes: HermesService?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let recent = library.homeList(.recent)
        let newest = library.homeList(.newest)
        let frequent = library.homeList(.frequent)
        let starred = library.homeList(.starred)
        let random = library.homeList(.random)
        let playlists = library.playlists()
        let counts = library.counts()
        let continueListening = library.recentlyPlayedSongs(limit: 24)
        let topPicks = library.topPicks()
        let listenAgain = library.listenAgain()
        let rediscover = library.rediscover()
        let onThisDay = library.onThisDay()
        let newArtists = library.recentlyAddedArtists()
        let genres = library.topGenres()

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if isFirstFullSync(counts: counts) {
                    syncBanner
                }

                if !newest.isLoaded && !recent.isLoaded && !counts.isLoaded {
                    loadingSkeletons
                } else if counts.isLoaded && counts.value.albums == 0 && counts.value.songs == 0 && !app.syncStatus.isSyncing {
                    emptyLibraryState
                } else {
                    if !topPicks.value.isEmpty {
                        topPicksShelf(topPicks.value)
                    }

                    upNextShelf

                    if !continueListening.value.isEmpty {
                        SongColumnsShelf(title: "Continue Listening", songs: continueListening.value, route: .songList(.recentlyPlayed))
                    }

                    if !recent.value.isEmpty {
                        albumShelf(title: "Recently Played", items: recent.value, route: .albumList(.recentlyPlayed))
                    }

                    if !listenAgain.value.isEmpty {
                        albumShelf(title: "Listen Again", items: listenAgain.value, route: .albumList(.listenAgain))
                    }

                    if !newest.value.isEmpty {
                        albumShelf(title: "Recently Added", items: newest.value, route: .albumList(.recentlyAdded))
                    }

                    if !onThisDay.value.isEmpty {
                        albumShelf(title: "On This Day", subtitle: "Played or added on \(Date().formatted(.dateTime.month(.wide).day())) in years past", items: onThisDay.value, route: nil)
                    }

                    if !rediscover.value.isEmpty {
                        albumShelf(title: "Rediscover", subtitle: "Favorites you haven’t played in a while", items: rediscover.value, route: .albumList(.rediscover))
                    }

                    if !frequent.value.isEmpty {
                        albumShelf(title: "Most Played", items: frequent.value, route: .albumList(.frequentlyPlayed))
                    }

                    if !newArtists.value.isEmpty {
                        artistsShelf(newArtists.value)
                    }

                    ForEach(genres.value) { genre in
                        GenreShelf(genre: genre.value)
                    }

                    if !starred.value.isEmpty {
                        albumShelf(title: "Favorite Albums", items: starred.value, route: .albumList(.favorites))
                    }

                    if !random.value.isEmpty {
                        albumShelf(title: "Random", items: random.value, route: .albumList(.random))
                    }

                    if !playlists.value.isEmpty {
                        playlistsShelf(playlists: playlists.value)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(app.activeAccount?.name ?? "Home")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarMenu
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                AccountAvatarMenu()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .refreshable {
            await app.pullToRefresh()
            await library.refreshHomeLists()
        }
        .observing(recent)
        .observing(newest)
        .observing(frequent)
        .observing(starred)
        .observing(random)
        .observing(playlists)
        .observing(counts)
        .observing(continueListening)
        .observing(topPicks)
        .observing(listenAgain)
        .observing(rediscover)
        .observing(onThisDay)
        .observing(newArtists)
        .observing(genres)
    }

    // MARK: - Sync Banner

    private func isFirstFullSync(counts: LiveQuery<LibraryCounts>) -> Bool {
        app.syncStatus.isSyncing && (app.syncStatus.isInitialSync || (counts.isLoaded && counts.value.albums == 0 && counts.value.songs == 0))
    }

    private var syncBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(app.syncStatus.phase.isEmpty ? "Syncing library…" : app.syncStatus.phase)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
                Spacer()
                if app.syncStatus.fraction > 0 {
                    Text(app.syncStatus.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryLabel)
                        .contentTransition(.numericText())
                }
            }
            if app.syncStatus.fraction > 0 {
                ProgressView(value: app.syncStatus.fraction)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.margin)
        .animation(.smooth, value: app.syncStatus.fraction)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Top Picks

    private func topPicksShelf(_ albums: [Album]) -> some View {
        let width: CGFloat = sizeClass == .regular ? 300 : 250
        return ShelfSection(title: "Top Picks for You", items: albums, tileWidth: width) { album in
            NavigationLink(value: Route.album(album.id)) {
                TopPickCard(album: album, reason: topPickReason(album), width: width)
            }
            .buttonStyle(.plain)
            .contextMenu { AlbumContextMenu(album: album) }
        }
        .scrollClipDisabled()
    }

    private func topPickReason(_ album: Album) -> String {
        if album.starred != nil { return "From your favorites" }
        if let artist = album.artist { return "Because you play \(artist)" }
        return "Picked for you"
    }

    // MARK: - Up Next Shelf

    @ViewBuilder
    private var upNextShelf: some View {
        if !player.upcoming.isEmpty {
            ShelfSection(title: "Up Next", items: player.upcoming, onHeaderTap: {
                ui?.playerPanel = .queue
                ui?.isPlayerPresented = true
            }) { entry in
                Button {
                    if let offset = player.upcoming.firstIndex(where: { $0.id == entry.id }) {
                        Haptics.impact(.light)
                        player.skip(toUpcomingOffset: offset)
                    }
                } label: {
                    AlbumTile(coverArt: entry.song.coverArt, title: entry.song.title, subtitle: entry.song.artist)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    SongActionsMenu(song: entry.song)
                }
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Shelves

    private func albumShelf(title: String, subtitle: String? = nil, items: [Album], route: Route?) -> some View {
        ShelfSection(title: title, subtitle: subtitle, items: items, headerRoute: route) { album in
            NavigationLink(value: Route.album(album.id)) {
                AlbumTile(album: album)
            }
            .buttonStyle(.plain)
            .contextMenu {
                AlbumContextMenu(album: album)
            }
        }
        .scrollClipDisabled()
    }

    private func artistsShelf(_ artists: [Artist]) -> some View {
        ShelfSection(title: "Recently Added Artists", items: artists, headerRoute: .artists, tileWidth: sizeClass == .regular ? 160 : 120) { artist in
            NavigationLink(value: Route.artist(artist.id)) {
                AlbumTile(coverArt: artist.coverArt, title: artist.name, isCircle: true)
            }
            .buttonStyle(.plain)
        }
        .scrollClipDisabled()
    }

    private func playlistsShelf(playlists: [Playlist]) -> some View {
        ShelfSection(title: "Playlists", items: playlists, headerRoute: .playlists) { playlist in
            NavigationLink(value: Route.playlist(playlist.id)) {
                PlaylistTile(playlist: playlist)
            }
            .buttonStyle(.plain)
        }
        .scrollClipDisabled()
    }

    // MARK: - Loading & Empty States

    @ViewBuilder
    private var loadingSkeletons: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Recently Added")
                .padding(.horizontal, Theme.margin)
            SkeletonTileGrid(count: 4)
        }
    }

    @ViewBuilder
    private var emptyLibraryState: some View {
        EmptyStateView(
            title: "No Music",
            systemImage: "music.note",
            message: "Your library is empty. Pull down to refresh or check your server sync."
        )
        .padding(.top, 60)
    }

    // MARK: - Toolbar

    private var toolbarMenu: some View {
        Menu {
            if hermes?.settings.isConfigured == true {
                Button {
                    ui?.askKnight("")
                } label: {
                    Label("Ask Knight", systemImage: "sparkles")
                }

                Divider()
            }

            Button {
                Task {
                    await shuffleAll()
                }
            } label: {
                Label("Shuffle All", systemImage: "shuffle")
            }

            Button {
                Task {
                    await app.refresh(force: true)
                }
            } label: {
                Label("Refresh Library", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    private func shuffleAll() async {
        let songs: [Song]
        if let db = library.database {
            do {
                songs = try await db.pool.read { db in
                    try LibraryQueries.songs(db, sort: .title, search: "", limit: nil)
                }
            } catch {
                Log.database.error("Home shuffleAll query failed: \(error)")
                ui?.showToast("Couldn’t load songs to shuffle.")
                songs = []
            }
        } else {
            songs = library.songs(sort: .title).value
        }
        guard !songs.isEmpty else { return }
        Haptics.impact(.medium)
        player.play(songs, shuffle: true)
    }
}
