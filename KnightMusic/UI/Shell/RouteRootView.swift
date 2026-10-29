import SwiftUI

/// Root view for each section tab in the iPad sidebar.
struct RouteRootView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let id):
            if let browseId = id.youTubeBrowseId {
                YTAlbumView(browseId: browseId)
            } else {
                AlbumDetailView(albumId: id)
            }
        case .artist(let id):
            if let browseId = id.youTubeBrowseId {
                YTArtistView(browseId: browseId)
            } else {
                ArtistDetailView(artistId: id)
            }
        case .playlist(let id):
            if let browseId = id.youTubeBrowseId {
                YTPlaylistView(browseId: browseId)
            } else {
                PlaylistDetailView(playlistId: id)
            }
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
        case .replay:
            ReplayView()
        case .customize:
            CustomizeView()
        case .appIcons:
            AppIconView()
        case .knightChat(let id, let draft):
            KnightChatView(conversationId: id, initialDraft: draft)
        case .youTubeGrid(let browseId, let params, let title):
            YTGridView(target: YTBrowseTarget(browseId: browseId, params: params), title: title)
        case .youTubeSongs(let browseId, let params, let title):
            YTSongsView(target: YTBrowseTarget(browseId: browseId, params: params), title: title)
        case .youTubeDiscover:
            YTDiscoverView()
        case .youTubeMoodsAndGenres:
            YTMoodsAndGenresView()
        case .youTubeCategory(let browseId, let params, let title):
            YTCategoryView(target: YTBrowseTarget(browseId: browseId, params: params), title: title)
        }
    }
}

