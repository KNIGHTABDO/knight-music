import SwiftUI

/// Genre detail screen displaying albums or songs belonging to the genre.
struct GenreDetailView: View {
    let genre: String

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui

    @State private var selectedTab: Tab = .albums

    private enum Tab: String, CaseIterable {
        case albums = "Albums"
        case songs = "Songs"
    }

    var body: some View {
        let albumsQuery = library.albums(genre: genre)
        let songsQuery = library.songs(genre: genre)
        let playlists = library.playlists()

        VStack(spacing: 0) {
            // Segmented Picker
            Picker("Filter", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 8)

            // Content
            Group {
                switch selectedTab {
                case .albums:
                    albumsView(query: albumsQuery)
                case .songs:
                    songsView(query: songsQuery)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.large)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await app.pullToRefresh() }
        .observing(albumsQuery)
        .observing(songsQuery)
        .observing(playlists)
    }

    // MARK: - Albums View

    @ViewBuilder
    private func albumsView(query: LiveQuery<[Album]>) -> some View {
        if !query.isLoaded {
            ScrollView {
                SkeletonTileGrid()
                    .padding(.top, 12)
            }
        } else if query.value.isEmpty {
            EmptyStateView(
                title: "No Albums",
                systemImage: "square.stack",
                message: "No albums found for “\(genre)”."
            )
        } else {
            ScrollView {
                AdaptiveAlbumGrid(items: query.value) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        AlbumTile(album: album)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Songs View

    @ViewBuilder
    private func songsView(query: LiveQuery<[Song]>) -> some View {
        let songs = query.value

        if !query.isLoaded {
            ScrollView {
                SkeletonRowList(count: 8)
                    .padding(.top, 12)
            }
        } else if songs.isEmpty {
            EmptyStateView(
                title: "No Songs",
                systemImage: "music.note",
                message: "No songs found for “\(genre)”."
            )
        } else {
            SongCollectionList(songs: songs)
        }
    }
}
