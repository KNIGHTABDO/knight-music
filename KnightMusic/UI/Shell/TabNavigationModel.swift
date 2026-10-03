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
}
