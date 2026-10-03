import SwiftUI

struct LibraryHubView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library

    private struct HubItem: Identifiable {
        let title: String
        let icon: String
        let route: Route
        var id: String { title }
    }

    private let hubItems: [HubItem] = [
        HubItem(title: "Playlists", icon: "music.note.list", route: .playlists),
        HubItem(title: "Artists", icon: "music.mic", route: .artists),
        HubItem(title: "Albums", icon: "square.stack", route: .albums),
        HubItem(title: "Songs", icon: "music.note", route: .songs),
        HubItem(title: "Genres", icon: "guitars", route: .genres),
        HubItem(title: "Favorite Artists", icon: "heart.fill", route: .favoriteArtists),
        HubItem(title: "Favorite Albums", icon: "heart.fill", route: .albumList(.favorites)),
        HubItem(title: "Favorite Songs", icon: "heart.fill", route: .songList(.favorites)),
        HubItem(title: "Downloaded", icon: "arrow.down.circle", route: .songList(.downloaded)),
        HubItem(title: "Radio Stations", icon: "antenna.radiowaves.left.and.right", route: .radioStations),
        HubItem(title: "Recently Played", icon: "clock", route: .albumList(.recentlyPlayed)),
        HubItem(title: "Frequently Played", icon: "flame", route: .albumList(.frequentlyPlayed)),
        HubItem(title: "Random", icon: "shuffle", route: .albumList(.random))
    ]

    var body: some View {
        let newestQuery = library.homeList(.newest)
        let recentAlbums = Array(newestQuery.value.prefix(12))

        List {
            Section {
                ForEach(hubItems) { item in
                    NavigationLink(value: item.route) {
                        HStack(spacing: 14) {
                            Image(systemName: item.icon)
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28, alignment: .center)

                            Text(item.title)
                                .font(.kmRowTitle)
                                .foregroundStyle(Theme.label)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Recently Added")
                        .padding(.horizontal, Theme.margin)

                    if !newestQuery.isLoaded {
                        SkeletonTileGrid(count: 6)
                    } else if !recentAlbums.isEmpty {
                        AdaptiveAlbumGrid(items: recentAlbums) { album in
                            NavigationLink(value: Route.album(album.id)) {
                                AlbumTile(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                AlbumContextMenu(album: album)
                            }
                        }
                    } else {
                        Text("No recently added albums")
                            .font(.kmRowSubtitle)
                            .foregroundStyle(Theme.secondaryLabel)
                            .padding(.horizontal, Theme.margin)
                    }
                }
                .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 30, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Library")
        .refreshable { await app.pullToRefresh() }
        .observing(newestQuery)
    }
}
