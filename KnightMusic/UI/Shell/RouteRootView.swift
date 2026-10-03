import SwiftUI

/// Root view for each section tab in the iPad sidebar.
struct RouteRootView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let id):
            AlbumDetailView(albumId: id)
        case .artist(let id):
            ArtistDetailView(artistId: id)
        case .playlist(let id):
            PlaylistDetailView(playlistId: id)
        case .genre(let name):
            GenreDetailView(genre: name)
        case .albumList(let kind):
            AlbumListView(kind: kind)
        case .songList(let kind):
            SongListView(kind: kind)
        case .artists:
            ArtistsView()
        case .favoriteArtists:
            FavoriteArtistsView()
        case .albums:
            AlbumsView()
        case .songs:
            SongsView()
        case .playlists:
            PlaylistsView()
        case .genres:
            GenresView()
        case .radioStations:
            RadioStationsView()
        }
    }
}
