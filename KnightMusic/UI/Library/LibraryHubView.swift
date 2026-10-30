import SwiftUI

struct LibraryHubView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library

    private struct HubItem: Identifiable, Equatable {
        let title: String
        let icon: String
        let route: Route
        var id: String { title }
    }

    private static let orderDefaultsKey = "library_hub_order"

    private static let defaultItems: [HubItem] = [
        HubItem(title: "Playlists", icon: "music.note.list", route: .playlists),
        HubItem(title: "Artists", icon: "music.mic", route: .artists),
        HubItem(title: "Albums", icon: "square.stack", route: .albums),
        HubItem(title: "Songs", icon: "music.note", route: .songs),
        HubItem(title: "Genres", icon: "guitars", route: .genres),
        HubItem(title: "Favorite Artists", icon: "heart.fill", route: .favoriteArtists),
        HubItem(title: "Favorite Albums", icon: "heart.fill", route: .albumList(.favorites)),
        HubItem(title: "Favorite Songs", icon: "heart.fill", route: .songList(.favorites)),
        HubItem(title: "Downloaded", icon: "arrow.down.circle", route: .songList(.downloaded)),
        HubItem(title: "Identified Songs", icon: "shazam.logo.fill", route: .identifiedSongs),
        HubItem(title: "Radio Stations", icon: "antenna.radiowaves.left.and.right", route: .radioStations),
        HubItem(title: "Discover", icon: "globe", route: .youTubeDiscover),
        HubItem(title: "Recently Played", icon: "clock", route: .albumList(.recentlyPlayed)),
        HubItem(title: "Frequently Played", icon: "flame", route: .albumList(.frequentlyPlayed)),
        HubItem(title: "Random", icon: "shuffle", route: .albumList(.random)),
        HubItem(title: "Knight Replay", icon: "chart.bar.xaxis", route: .replay)
    ]

    @State private var hubItems: [HubItem] = Self.loadOrderedItems()
    @State private var editMode: EditMode = .inactive

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
                .onMove(perform: moveItems)
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
            .environment(\.editMode, .constant(.inactive))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Library")
        .environment(\.editMode, $editMode)
        .toolbar {
            if editMode == .active {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        withAnimation {
                            resetOrder()
                        }
                    }
                    .foregroundStyle(Theme.secondaryLabel)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "Done" : "Edit") {
                    withAnimation {
                        editMode = editMode == .active ? .inactive : .active
                    }
                }
                .fontWeight(editMode == .active ? .semibold : .regular)
            }
        }
        .refreshable { await app.pullToRefresh() }
        .observing(newestQuery)
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        hubItems.move(fromOffsets: source, toOffset: destination)
        saveOrder()
    }

    private func resetOrder() {
        hubItems = Self.defaultItems
        UserDefaults.standard.removeObject(forKey: Self.orderDefaultsKey)
    }

    private func saveOrder() {
        let order = hubItems.map(\.id)
        UserDefaults.standard.set(order, forKey: Self.orderDefaultsKey)
    }

    private static func loadOrderedItems() -> [HubItem] {
        guard let savedOrder = UserDefaults.standard.stringArray(forKey: orderDefaultsKey),
              !savedOrder.isEmpty else {
            return defaultItems
        }

        var itemMap = Dictionary(uniqueKeysWithValues: defaultItems.map { ($0.id, $0) })
        var ordered: [HubItem] = []

        for id in savedOrder {
            if let item = itemMap.removeValue(forKey: id) {
                ordered.append(item)
            }
        }

        for item in defaultItems where itemMap[item.id] != nil {
            ordered.append(item)
        }

        return ordered.isEmpty ? defaultItems : ordered
    }
}
