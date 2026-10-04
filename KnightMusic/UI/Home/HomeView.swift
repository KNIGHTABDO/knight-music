import SwiftUI
import GRDB

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui: UIState?
    @Environment(HermesService.self) private var hermes: HermesService?

    var body: some View {
        let recent = library.homeList(.recent)
        let newest = library.homeList(.newest)
        let frequent = library.homeList(.frequent)
        let starred = library.homeList(.starred)
        let random = library.homeList(.random)
        let playlists = library.playlists()
        let counts = library.counts()

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
                    upNextShelf

                    if !recent.value.isEmpty {
                        albumShelf(title: "Recently Played", items: recent.value, route: .albumList(.recentlyPlayed))
                    }

                    if !newest.value.isEmpty {
                        albumShelf(title: "Recently Added", items: newest.value, route: .albumList(.recentlyAdded))
                    }

                    if !frequent.value.isEmpty {
                        albumShelf(title: "Most Played", items: frequent.value, route: .albumList(.frequentlyPlayed))
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
    }

    // MARK: - Sync Banner

    private func isFirstFullSync(counts: LiveQuery<LibraryCounts>) -> Bool {
        app.syncStatus.isSyncing && (app.syncStatus.isInitialSync || (counts.isLoaded && counts.value.albums == 0 && counts.value.songs == 0))
    }

    @ViewBuilder
    private var syncBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(app.syncStatus.phase.isEmpty ? "Syncing library..." : app.syncStatus.phase)
                    .font(.kmTileSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
                Spacer()
                if app.syncStatus.fraction > 0 {
                    Text("\(Int(app.syncStatus.fraction * 100))%")
                        .font(.kmTileSubtitle.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryLabel)
                }
            }
            ProgressView(value: app.syncStatus.fraction > 0 ? app.syncStatus.fraction : nil)
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemGray6).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - Up Next Shelf

    @ViewBuilder
    private var upNextShelf: some View {
        if player.upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Up Next", action: {
                    ui?.playerPanel = .queue
                    ui?.isPlayerPresented = true
                })
                .padding(.horizontal, Theme.margin)

                Text("No items available...")
                    .font(.kmTileTitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding(.horizontal, Theme.margin)
            }
        } else {
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

    // MARK: - Album Shelf

    private func albumShelf(title: String, items: [Album], route: Route) -> some View {
        ShelfSection(title: title, items: items, onHeaderTap: {}) { album in
            NavigationLink(value: Route.album(album.id)) {
                AlbumTile(album: album)
            }
            .buttonStyle(.plain)
            .contextMenu {
                AlbumContextMenu(album: album)
            }
        }
        .scrollClipDisabled()
        .overlay(alignment: .top) {
            NavigationLink(value: route) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }

    // MARK: - Playlists Shelf

    private func playlistsShelf(playlists: [Playlist]) -> some View {
        ShelfSection(title: "Playlists", items: playlists, onHeaderTap: {}) { playlist in
            NavigationLink(value: Route.playlist(playlist.id)) {
                PlaylistTile(playlist: playlist)
            }
            .buttonStyle(.plain)
        }
        .scrollClipDisabled()
        .overlay(alignment: .top) {
            NavigationLink(value: Route.playlists) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playlists")
        }
    }

    // MARK: - Loading & Empty States

    @ViewBuilder
    private var loadingSkeletons: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Up Next")
                .padding(.horizontal, Theme.margin)
            Text("No items available...")
                .font(.kmTileTitle)
                .foregroundStyle(Theme.secondaryLabel)
                .padding(.horizontal, Theme.margin)

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
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.label)
        }
    }

    private func shuffleAll() async {
        let songs: [Song]
        if let db = library.database {
            songs = (try? await db.pool.read { db in
                try LibraryQueries.songs(db, sort: .title, search: "", limit: nil)
            }) ?? []
        } else {
            songs = library.songs(sort: .title).value
        }
        guard !songs.isEmpty else { return }
        Haptics.impact(.medium)
        player.play(songs, shuffle: true)
    }
}
