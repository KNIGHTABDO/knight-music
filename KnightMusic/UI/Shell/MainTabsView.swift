import SwiftUI

struct MainTabsView: View {
    @Environment(UIState.self) private var ui
    @Environment(AppModel.self) private var app
    @Environment(PlayerEngine.self) private var player
    @Environment(TabNavigationModel.self) private var nav
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Namespace private var playerZoomNamespace

    private struct LibraryTabItem: Identifiable {
        let id: Route
        let title: String
        let systemImage: String
        let route: Route
    }

    private static let libraryItems: [LibraryTabItem] = [
        LibraryTabItem(id: .artists, title: "Artists", systemImage: "music.mic", route: .artists),
        LibraryTabItem(id: .albums, title: "Albums", systemImage: "square.stack", route: .albums),
        LibraryTabItem(id: .songs, title: "Songs", systemImage: "music.note", route: .songs),
        LibraryTabItem(id: .favoriteArtists, title: "Favorite Artists", systemImage: "heart.fill", route: .favoriteArtists),
        LibraryTabItem(id: .albumList(.favorites), title: "Favorite Albums", systemImage: "heart.fill", route: .albumList(.favorites)),
        LibraryTabItem(id: .songList(.favorites), title: "Favorite Songs", systemImage: "heart.fill", route: .songList(.favorites)),
        LibraryTabItem(id: .songList(.downloaded), title: "Downloaded Songs", systemImage: "arrow.down.circle", route: .songList(.downloaded)),
        LibraryTabItem(id: .radioStations, title: "Radio Stations", systemImage: "dot.radiowaves.left.and.right", route: .radioStations),
        LibraryTabItem(id: .genres, title: "Genres", systemImage: "guitars", route: .genres),
        LibraryTabItem(id: .playlists, title: "Playlists", systemImage: "music.note.list", route: .playlists),
        LibraryTabItem(id: .albumList(.recentlyPlayed), title: "Recently Played", systemImage: "clock", route: .albumList(.recentlyPlayed)),
        LibraryTabItem(id: .albumList(.recentlyAdded), title: "Recently Added", systemImage: "plus.square.on.square", route: .albumList(.recentlyAdded)),
        LibraryTabItem(id: .albumList(.frequentlyPlayed), title: "Frequently Played", systemImage: "flame", route: .albumList(.frequentlyPlayed)),
        LibraryTabItem(id: .albumList(.random), title: "Random", systemImage: "shuffle", route: .albumList(.random))
    ]

    var body: some View {
        @Bindable var ui = ui

        Group {
            if horizontalSizeClass == .regular {
                regularTabs
            } else {
                compactTabs
            }
        }
        .fullScreenCover(isPresented: $ui.isPlayerPresented) {
            FullPlayerView()
                .navigationTransition(.zoom(sourceID: "nowPlayingArtwork", in: playerZoomNamespace))
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            keepSelectedTabValid(for: newSizeClass)
        }
        .onAppear {
            keepSelectedTabValid(for: horizontalSizeClass)
        }
    }

    private var regularTabs: some View {
        @Bindable var ui = ui
        @Bindable var nav = nav

        return TabView(selection: $ui.selectedTab) {
            Tab("Home", systemImage: "house", value: UIState.Tab.home) {
                NavigationStack(path: $nav.home) {
                    HomeView()
                        .withAppRoutes()
                }
            }

            Tab(value: UIState.Tab.search, role: .search) {
                NavigationStack(path: $nav.search) {
                    SearchView()
                        .withAppRoutes()
                }
            }

            Tab("Settings", systemImage: "gearshape", value: UIState.Tab.settings) {
                NavigationStack(path: $nav.settings) {
                    SettingsView()
                        .withAppRoutes()
                }
            }

            TabSection("Library") {
                ForEach(Self.libraryItems) { item in
                    Tab(item.title, systemImage: item.systemImage, value: UIState.Tab.section(item.route)) {
                        NavigationStack(path: nav.binding(for: item.route)) {
                            RouteRootView(route: item.route)
                                .withAppRoutes()
                        }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSidebarHeader {
            if let name = app.activeAccount?.name, !name.isEmpty {
                Text(name.uppercased())
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .tabViewBottomAccessory {
            if player.currentSong != nil {
                MiniPlayerView(namespace: playerZoomNamespace)
            }
        }
    }

    private var compactTabs: some View {
        @Bindable var ui = ui
        @Bindable var nav = nav

        return TabView(selection: $ui.selectedTab) {
            Tab("Home", systemImage: "house", value: UIState.Tab.home) {
                NavigationStack(path: $nav.home) {
                    HomeView()
                        .withAppRoutes()
                }
            }

            Tab("Library", systemImage: "square.stack.fill", value: UIState.Tab.library) {
                NavigationStack(path: $nav.library) {
                    LibraryHubView()
                        .withAppRoutes()
                }
            }

            Tab("Settings", systemImage: "gearshape", value: UIState.Tab.settings) {
                NavigationStack(path: $nav.settings) {
                    SettingsView()
                        .withAppRoutes()
                }
            }

            Tab(value: UIState.Tab.search, role: .search) {
                NavigationStack(path: $nav.search) {
                    SearchView()
                        .withAppRoutes()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if player.currentSong != nil {
                MiniPlayerView(namespace: playerZoomNamespace)
            }
        }
    }

    private func keepSelectedTabValid(for sizeClass: UserInterfaceSizeClass?) {
        if sizeClass == .compact {
            if case .section = ui.selectedTab {
                ui.selectedTab = .library
            }
        } else if sizeClass == .regular {
            if ui.selectedTab == .library {
                ui.selectedTab = .section(.albums)
            }
        }
    }
}
