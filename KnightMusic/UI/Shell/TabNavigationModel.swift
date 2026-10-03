import SwiftUI

/// Programmatic navigation paths for every tab and sidebar section in the app.
@MainActor @Observable
final class TabNavigationModel {
    var home = NavigationPath()
    var search = NavigationPath()
    var settings = NavigationPath()
    var library = NavigationPath()

    // Section tabs on iPad (UIState.Tab.section(route))
    var artists = NavigationPath()
    var albums = NavigationPath()
    var songs = NavigationPath()
    var favoriteArtists = NavigationPath()
    var favoriteAlbums = NavigationPath()
    var favoriteSongs = NavigationPath()
    var downloaded = NavigationPath()
    var radioStations = NavigationPath()
    var genres = NavigationPath()
    var playlists = NavigationPath()
    var recentlyPlayed = NavigationPath()
    var recentlyAdded = NavigationPath()
    var frequentlyPlayed = NavigationPath()
    var random = NavigationPath()

    func binding(for route: Route) -> Binding<NavigationPath> {
        switch route {
        case .artists:
            return Binding(get: { self.artists }, set: { self.artists = $0 })
        case .albums:
            return Binding(get: { self.albums }, set: { self.albums = $0 })
        case .songs:
            return Binding(get: { self.songs }, set: { self.songs = $0 })
        case .favoriteArtists:
            return Binding(get: { self.favoriteArtists }, set: { self.favoriteArtists = $0 })
        case .albumList(let kind):
            switch kind {
            case .favorites:
                return Binding(get: { self.favoriteAlbums }, set: { self.favoriteAlbums = $0 })
            case .recentlyPlayed:
                return Binding(get: { self.recentlyPlayed }, set: { self.recentlyPlayed = $0 })
            case .recentlyAdded:
                return Binding(get: { self.recentlyAdded }, set: { self.recentlyAdded = $0 })
            case .frequentlyPlayed:
                return Binding(get: { self.frequentlyPlayed }, set: { self.frequentlyPlayed = $0 })
            case .random:
                return Binding(get: { self.random }, set: { self.random = $0 })
            }
        case .songList(let kind):
            switch kind {
            case .favorites:
                return Binding(get: { self.favoriteSongs }, set: { self.favoriteSongs = $0 })
            case .downloaded:
                return Binding(get: { self.downloaded }, set: { self.downloaded = $0 })
            case .recentlyAdded:
                return Binding(get: { self.songs }, set: { self.songs = $0 })
            }
        case .radioStations:
            return Binding(get: { self.radioStations }, set: { self.radioStations = $0 })
        case .genres:
            return Binding(get: { self.genres }, set: { self.genres = $0 })
        case .playlists:
            return Binding(get: { self.playlists }, set: { self.playlists = $0 })
        default:
            return Binding(get: { self.library }, set: { self.library = $0 })
        }
    }
}
