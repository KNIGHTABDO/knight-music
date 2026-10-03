import SwiftUI

/// Genre detail screen displaying albums or songs belonging to the genre.
struct GenreDetailView: View {
    let genre: String

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui

    @State private var selectedTab: Tab = .albums

    private enum Tab: String, CaseIterable {
        case albums = "Albums"
        case songs = "Songs"
    }

    var body: some View {
        let albumsQuery = library.albums(genre: genre)
        let songsQuery = library.songs(genre: genre)
        let playlists = library.playlists()

        VStack(spacing: 0) {
            // Segmented Picker
            Picker("Filter", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 8)

            // Content
            Group {
                switch selectedTab {
                case .albums:
                    albumsView(query: albumsQuery)
                case .songs:
                    songsView(query: songsQuery)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.large)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await app.pullToRefresh() }
        .observing(albumsQuery)
        .observing(songsQuery)
        .observing(playlists)
    }

    // MARK: - Albums View

    @ViewBuilder
    private func albumsView(query: LiveQuery<[Album]>) -> some View {
        if !query.isLoaded {
            ScrollView {
                SkeletonTileGrid()
                    .padding(.top, 12)
            }
        } else if query.value.isEmpty {
            EmptyStateView(
                title: "No Albums",
                systemImage: "square.stack",
                message: "No albums found for “\(genre)”."
            )
        } else {
            ScrollView {
                AdaptiveAlbumGrid(items: query.value) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        AlbumTile(album: album)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Songs View

    @ViewBuilder
    private func songsView(query: LiveQuery<[Song]>) -> some View {
        let songs = query.value

        if !query.isLoaded {
            ScrollView {
                SkeletonRowList(count: 8)
                    .padding(.top, 12)
            }
        } else if songs.isEmpty {
            EmptyStateView(
                title: "No Songs",
                systemImage: "music.note",
                message: "No songs found for “\(genre)”."
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    // Play / Shuffle glass buttons
                    HStack(spacing: 12) {
                        Button {
                            Haptics.impact(.medium)
                            player.play(songs, startAt: 0, shuffle: false)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.glass)
                        .tint(Theme.accent)

                        Button {
                            Haptics.impact(.medium)
                            player.play(songs, shuffle: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.glass)
                        .tint(Theme.accent)
                    }
                    .padding(.horizontal, Theme.margin)
                    .padding(.vertical, 8)

                    // Song rows
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            let isPlaying = player.currentSong?.id == song.id
                            let isPaused = isPlaying && !player.isPlaying
                            let isDownloaded = downloads.isDownloaded(song.id)

                            Button {
                                Haptics.selection()
                                player.play(songs, startAt: index, shuffle: false)
                            } label: {
                                SongRow(
                                    song: song,
                                    showsArtwork: true,
                                    isPlaying: isPlaying,
                                    isPaused: isPaused,
                                    isDownloaded: isDownloaded
                                ) {
                                    SongActionsMenu(song: song)
                                }
                                .padding(.horizontal, Theme.margin)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                SongActionsMenu(song: song)
                            }

                            Divider().padding(.leading, Theme.margin + 48 + 12)
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
    }
}
