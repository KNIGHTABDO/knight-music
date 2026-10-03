import SwiftUI

struct AlbumListView: View {
    let kind: AlbumListKind

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library

    var body: some View {
        let query = albumsQuery()
        let albums = query.value

        ScrollView {
            if !query.isLoaded {
                SkeletonTileGrid()
                    .padding(.vertical, Theme.margin)
            } else if albums.isEmpty {
                let empty = emptyMessage
                EmptyStateView(
                    title: empty.title,
                    systemImage: empty.symbol,
                    message: empty.message
                )
                .padding(.top, 60)
            } else {
                AdaptiveAlbumGrid(items: albums) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        AlbumTile(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AlbumContextMenu(album: album)
                    }
                }
                .padding(.vertical, Theme.margin)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(kind.title)
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            if kind == .random {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        Task { await library.refreshHomeLists() }
                    } label: {
                        Label("Shuffle again", systemImage: "shuffle")
                    }
                }
            }
        }
        .observing(query)
    }

    private func albumsQuery() -> LiveQuery<[Album]> {
        switch kind {
        case .recentlyPlayed:
            return library.albums(sort: .recentlyPlayed)
        case .recentlyAdded:
            return library.albums(sort: .recentlyAdded)
        case .frequentlyPlayed:
            return library.albums(sort: .mostPlayed)
        case .random:
            return library.homeList(.random)
        case .favorites:
            return library.favoriteAlbums()
        }
    }

    private var emptyMessage: (title: String, symbol: String, message: String) {
        switch kind {
        case .recentlyPlayed:
            return ("No Recently Played", "clock", "Albums you play will appear here.")
        case .recentlyAdded:
            return ("No Recently Added", "square.stack", "Recently added albums will appear here.")
        case .frequentlyPlayed:
            return ("No Frequently Played", "flame", "Albums you play frequently will appear here.")
        case .random:
            return ("No Albums", "shuffle", "No albums found in your library.")
        case .favorites:
            return ("No Favorite Albums", "heart.slash", "Favorite albums to see them here.")
        }
    }
}
