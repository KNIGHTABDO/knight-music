import SwiftUI

struct SongListView: View {
    let kind: SongListKind

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        let query = songsQuery()
        let songs = query.value

        Group {
            if !query.isLoaded {
                List {
                    SkeletonRowList(count: 10)
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if songs.isEmpty {
                let empty = emptyMessage
                EmptyStateView(
                    title: empty.title,
                    systemImage: empty.symbol,
                    message: empty.message
                )
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Button {
                                Haptics.impact(.medium)
                                player.play(songs, shuffle: false)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.kmRowTitle)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.glass)

                            Button {
                                Haptics.impact(.medium)
                                player.play(songs, shuffle: true)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .font(.kmRowTitle)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.glass)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(songs) { song in
                            SongRow(
                                song: song,
                                showsArtwork: true,
                                isPlaying: player.currentSong?.id == song.id,
                                isPaused: !player.isPlaying,
                                isDownloaded: downloads.isDownloaded(song.id)
                            ) {
                                SongActionsMenu(song: song)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.impact(.medium)
                                if let index = songs.firstIndex(where: { $0.id == song.id }) {
                                    player.play(songs, startAt: index, shuffle: false)
                                } else {
                                    player.play(songs, shuffle: false)
                                }
                            }
                            .contextMenu {
                                SongActionsMenu(song: song)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(kind.title)
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            if kind == .downloaded {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        let count = downloads.completedCount
                        let size = StorageManager.format(downloads.completedBytes)
                        Text("\(count) \(count == 1 ? "song" : "songs") • \(size)")

                        Button(role: .destructive) {
                            showDeleteAllConfirmation = true
                        } label: {
                            Label("Delete All Downloads", systemImage: "trash")
                        }
                        .disabled(count == 0)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete All Downloads?",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive) {
                downloads.deleteAll()
            }
        } message: {
            Text("This will remove all downloaded songs from this device.")
        }
        .observing(query)
    }

    private func songsQuery() -> LiveQuery<[Song]> {
        switch kind {
        case .favorites:
            return library.favoriteSongs()
        case .downloaded:
            return library.downloadedSongs()
        case .recentlyAdded:
            return library.recentlyAddedSongs()
        }
    }

    private var emptyMessage: (title: String, symbol: String, message: String) {
        switch kind {
        case .favorites:
            return ("No Favorite Songs", "heart.slash", "Favorite songs to listen to them here.")
        case .downloaded:
            return ("No Downloads", "arrow.down.circle", "Download albums or songs to listen offline.")
        case .recentlyAdded:
            return ("No Recently Added Songs", "clock", "Recently added songs will appear here.")
        }
    }
}
