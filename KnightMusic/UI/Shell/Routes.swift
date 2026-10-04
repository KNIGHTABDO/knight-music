import SwiftUI

/// Every push destination in the app. Views navigate with `NavigationLink(value: Route.album(id))`;
/// each tab's NavigationStack applies `.withAppRoutes()` once.
enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case genre(String)
    case albumList(AlbumListKind)
    case songList(SongListKind)
    case artists
    case favoriteArtists
    case albums
    case songs
    case playlists
    case genres
    case radioStations
    case knightChat(id: String, draft: String? = nil)
}


/// Album grids reachable from the sidebar / home shelves ("Recently Played ›").
enum AlbumListKind: String, Hashable, CaseIterable {
    case recentlyPlayed, recentlyAdded, frequentlyPlayed, random, favorites

    var title: String {
        switch self {
        case .recentlyPlayed: "Recently Played"
        case .recentlyAdded: "Recently Added"
        case .frequentlyPlayed: "Frequently Played"
        case .random: "Random"
        case .favorites: "Favorite Albums"
        }
    }
}

enum SongListKind: String, Hashable, CaseIterable {
    case favorites, downloaded, recentlyAdded

    var title: String {
        switch self {
        case .favorites: "Favorite Songs"
        case .downloaded: "Downloaded Songs"
        case .recentlyAdded: "Recently Added Songs"
        }
    }
}

extension View {
    func withAppRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id): AlbumDetailView(albumId: id)
            case .artist(let id): ArtistDetailView(artistId: id)
            case .playlist(let id): PlaylistDetailView(playlistId: id)
            case .genre(let name): GenreDetailView(genre: name)
            case .albumList(let kind): AlbumListView(kind: kind)
            case .songList(let kind): SongListView(kind: kind)
            case .artists: ArtistsView()
            case .favoriteArtists: FavoriteArtistsView()
            case .albums: AlbumsView()
            case .songs: SongsView()
            case .playlists: PlaylistsView()
            case .genres: GenresView()
            case .radioStations: RadioStationsView()
            case .knightChat(let id, let draft): KnightChatView(conversationId: id, initialDraft: draft)
            }

        }
    }
}
