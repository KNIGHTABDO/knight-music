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
    case replay
    case customize
    case appIcons
    case knightChat(id: String, draft: String? = nil)
    case youTubeGrid(browseId: String, params: String?, title: String)
    case youTubeSongs(browseId: String, params: String?, title: String)
}


/// Album grids reachable from the sidebar / home shelves ("Recently Played ›").
enum AlbumListKind: String, Hashable, CaseIterable {
    case recentlyPlayed, recentlyAdded, frequentlyPlayed, random, favorites, rediscover, listenAgain

    var title: String {
        switch self {
        case .rediscover: "Rediscover"
        case .listenAgain: "Listen Again"
        case .recentlyPlayed: "Recently Played"
        case .recentlyAdded: "Recently Added"
        case .frequentlyPlayed: "Frequently Played"
        case .random: "Random"
        case .favorites: "Favorite Albums"
        }
    }
}

enum SongListKind: String, Hashable, CaseIterable {
    case favorites, downloaded, recentlyAdded, recentlyPlayed

    var title: String {
        switch self {
        case .recentlyPlayed: "Continue Listening"
        case .favorites: "Favorite Songs"
        case .downloaded: "Downloaded Songs"
        case .recentlyAdded: "Recently Added Songs"
        }
    }
}

extension View {
    func withAppRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteRootView(route: route)
        }
    }
}
