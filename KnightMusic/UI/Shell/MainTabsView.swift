import SwiftUI

struct MainTabsView: View {
    var playerZoomNamespace: Namespace.ID

    @AppStorage("sidebarCustomization") private var customization: TabViewCustomization = .init()

    @Environment(UIState.self) private var ui
    @Environment(AppModel.self) private var app
    @Environment(PlayerEngine.self) private var player
    @Environment(TabNavigationModel.self) private var nav
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private struct LibraryTabItem: Identifiable {
        let id: Route
        let title: String
        let systemImage: String
        let route: Route
        let customizationId: String
    }

    private static let libraryItems: [LibraryTabItem] = [
        LibraryTabItem(id: .artists, title: "Artists", systemImage: "music.mic", route: .artists, customizationId: "library.artists"),
        LibraryTabItem(id: .albums, title: "Albums", systemImage: "square.stack", route: .albums, customizationId: "library.albums"),
        LibraryTabItem(id: .songs, title: "Songs", systemImage: "music.note", route: .songs, customizationId: "library.songs"),
        LibraryTabItem(id: .favoriteArtists, title: "Favorite Artists", systemImage: "heart.fill", route: .favoriteArtists, customizationId: "library.favoriteArtists"),
        LibraryTabItem(id: .albumList(.favorites), title: "Favorite Albums", systemImage: "heart.fill", route: .albumList(.favorites), customizationId: "library.favoriteAlbums"),
        LibraryTabItem(id: .songList(.favorites), title: "Favorite Songs", systemImage: "heart.fill", route: .songList(.favorites), customizationId: "library.favoriteSongs"),
        LibraryTabItem(id: .songList(.downloaded), title: "Downloaded Songs", systemImage: "arrow.down.circle", route: .songList(.downloaded), customizationId: "library.downloadedSongs"),
        LibraryTabItem(id: .radioStations, title: "Radio Stations", systemImage: "dot.radiowaves.left.and.right", route: .radioStations, customizationId: "library.radioStations"),
        LibraryTabItem(id: .genres, title: "Genres", systemImage: "guitars", route: .genres, customizationId: "library.genres"),
        LibraryTabItem(id: .playlists, title: "Playlists", systemImage: "music.note.list", route: .playlists, customizationId: "library.playlists"),
        LibraryTabItem(id: .albumList(.recentlyPlayed), title: "Recently Played", systemImage: "clock", route: .albumList(.recentlyPlayed), customizationId: "library.recentlyPlayed"),
        LibraryTabItem(id: .albumList(.recentlyAdded), title: "Recently Added", systemImage: "plus.square.on.square", route: .albumList(.recentlyAdded), customizationId: "library.recentlyAdded"),
        LibraryTabItem(id: .albumList(.frequentlyPlayed), title: "Frequently Played", systemImage: "flame", route: .albumList(.frequentlyPlayed), customizationId: "library.frequentlyPlayed"),
        LibraryTabItem(id: .albumList(.random), title: "Random", systemImage: "shuffle", route: .albumList(.random), customizationId: "library.random")
    ]

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularTabs
            } else {
                compactTabs
            }
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
            .customizationID("tab.home")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            Tab(value: UIState.Tab.search, role: .search) {
                NavigationStack(path: $nav.search) {
                    SearchView()
                        .withAppRoutes()
                }
            }
            .customizationID("tab.search")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            Tab("Settings", systemImage: "gearshape", value: UIState.Tab.settings) {
                NavigationStack(path: $nav.settings) {
                    SettingsView()
                        .withAppRoutes()
                }
            }
            .customizationID("tab.settings")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            TabSection("Library") {
                ForEach(Self.libraryItems) { item in
                    Tab(item.title, systemImage: item.systemImage, value: UIState.Tab.section(item.route)) {
                        NavigationStack(path: nav.binding(for: item.route)) {
                            RouteRootView(route: item.route)
                                .withAppRoutes()
                        }
                    }
                    .customizationID(item.customizationId)
                }
            }
            .customizationID("section.library")
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.sidebar)
        .tabViewCustomization($customization)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSidebarHeader {
            let accountName = (app.activeAccount?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "KNIGHT"
            Text(accountName.uppercased())
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .miniPlayerBottomAccessory(isEnabled: player.currentSong != nil, namespace: playerZoomNamespace)
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
            .customizationID("compact.tab.home")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            Tab("Library", systemImage: "square.stack.fill", value: UIState.Tab.library) {
                NavigationStack(path: $nav.library) {
                    LibraryHubView()
                        .withAppRoutes()
                }
            }
            .customizationID("compact.tab.library")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            Tab("Settings", systemImage: "gearshape", value: UIState.Tab.settings) {
                NavigationStack(path: $nav.settings) {
                    SettingsView()
                        .withAppRoutes()
                }
            }
            .customizationID("compact.tab.settings")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            Tab(value: UIState.Tab.search, role: .search) {
                NavigationStack(path: $nav.search) {
                    SearchView()
                        .withAppRoutes()
                }
            }
            .customizationID("compact.tab.search")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .miniPlayerBottomAccessory(isEnabled: player.currentSong != nil, namespace: playerZoomNamespace)
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

private struct MiniPlayerBottomAccessoryModifier: ViewModifier {
    let isEnabled: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) {
                MiniPlayerView(namespace: namespace)
            }
        } else {
            if isEnabled {
                content.tabViewBottomAccessory {
                    MiniPlayerView(namespace: namespace)
                }
            } else {
                content
            }
        }
    }
}

private extension View {
    func miniPlayerBottomAccessory(isEnabled: Bool, namespace: Namespace.ID) -> some View {
        modifier(MiniPlayerBottomAccessoryModifier(isEnabled: isEnabled, namespace: namespace))
    }
}
