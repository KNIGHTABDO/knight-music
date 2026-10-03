import SwiftUI

struct MainTabsView: View {
    @Environment(UIState.self) private var ui
    @Environment(AppModel.self) private var app
    @Environment(PlayerEngine.self) private var player
    @Environment(TabNavigationModel.self) private var nav
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Namespace private var playerZoomNamespace

    var body: some View {
        @Bindable var ui = ui
        @Bindable var nav = nav

        TabView(selection: $ui.selectedTab) {
            if horizontalSizeClass == .regular {
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
                    Tab("Artists", systemImage: "music.mic", value: UIState.Tab.section(.artists)) {
                        NavigationStack(path: $nav.artists) {
                            RouteRootView(route: .artists)
                                .withAppRoutes()
                        }
                    }

                    Tab("Albums", systemImage: "square.stack", value: UIState.Tab.section(.albums)) {
                        NavigationStack(path: $nav.albums) {
                            RouteRootView(route: .albums)
                                .withAppRoutes()
                        }
                    }

                    Tab("Songs", systemImage: "music.note", value: UIState.Tab.section(.songs)) {
                        NavigationStack(path: $nav.songs) {
                            RouteRootView(route: .songs)
                                .withAppRoutes()
                        }
                    }

                    Tab("Favorite Artists", systemImage: "heart.fill", value: UIState.Tab.section(.favoriteArtists)) {
                        NavigationStack(path: $nav.favoriteArtists) {
                            RouteRootView(route: .favoriteArtists)
                                .withAppRoutes()
                        }
                    }

                    Tab("Favorite Albums", systemImage: "heart.fill", value: UIState.Tab.section(.albumList(.favorites))) {
                        NavigationStack(path: $nav.favoriteAlbums) {
                            RouteRootView(route: .albumList(.favorites))
                                .withAppRoutes()
                        }
                    }

                    Tab("Favorite Songs", systemImage: "heart.fill", value: UIState.Tab.section(.songList(.favorites))) {
                        NavigationStack(path: $nav.favoriteSongs) {
                            RouteRootView(route: .songList(.favorites))
                                .withAppRoutes()
                        }
                    }

                    Tab("Downloaded Songs", systemImage: "arrow.down.circle", value: UIState.Tab.section(.songList(.downloaded))) {
                        NavigationStack(path: $nav.downloaded) {
                            RouteRootView(route: .songList(.downloaded))
                                .withAppRoutes()
                        }
                    }

                    Tab("Radio Stations", systemImage: "dot.radiowaves.left.and.right", value: UIState.Tab.section(.radioStations)) {
                        NavigationStack(path: $nav.radioStations) {
                            RouteRootView(route: .radioStations)
                                .withAppRoutes()
                        }
                    }

                    Tab("Genres", systemImage: "guitars", value: UIState.Tab.section(.genres)) {
                        NavigationStack(path: $nav.genres) {
                            RouteRootView(route: .genres)
                                .withAppRoutes()
                        }
                    }

                    Tab("Playlists", systemImage: "music.note.list", value: UIState.Tab.section(.playlists)) {
                        NavigationStack(path: $nav.playlists) {
                            RouteRootView(route: .playlists)
                                .withAppRoutes()
                        }
                    }

                    Tab("Recently Played", systemImage: "clock", value: UIState.Tab.section(.albumList(.recentlyPlayed))) {
                        NavigationStack(path: $nav.recentlyPlayed) {
                            RouteRootView(route: .albumList(.recentlyPlayed))
                                .withAppRoutes()
                        }
                    }

                    Tab("Recently Added", systemImage: "plus.square.on.square", value: UIState.Tab.section(.albumList(.recentlyAdded))) {
                        NavigationStack(path: $nav.recentlyAdded) {
                            RouteRootView(route: .albumList(.recentlyAdded))
                                .withAppRoutes()
                        }
                    }

                    Tab("Frequently Played", systemImage: "flame", value: UIState.Tab.section(.albumList(.frequentlyPlayed))) {
                        NavigationStack(path: $nav.frequentlyPlayed) {
                            RouteRootView(route: .albumList(.frequentlyPlayed))
                                .withAppRoutes()
                        }
                    }

                    Tab("Random", systemImage: "shuffle", value: UIState.Tab.section(.albumList(.random))) {
                        NavigationStack(path: $nav.random) {
                            RouteRootView(route: .albumList(.random))
                                .withAppRoutes()
                        }
                    }
                }
            } else {
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
        .tabViewBottomAccessory(isEnabled: player.currentSong != nil) {
            MiniPlayerView(namespace: playerZoomNamespace)
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
