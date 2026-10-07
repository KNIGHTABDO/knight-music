import SwiftUI

struct SongsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var sort: SongSort = .title
    @State private var hasLoadedInitial = false
    @State private var previousSongs: [Song] = []

    var body: some View {
        let query = library.songs(sort: sort, search: debouncedSearchText)
        let songs = query.isLoaded ? query.value : (hasLoadedInitial ? previousSongs : query.value)
        let showSkeleton = !query.isLoaded && !hasLoadedInitial

        Group {
            if showSkeleton {
                List {
                    SkeletonRowList(count: 10)
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if songs.isEmpty {
                EmptyStateView(
                    title: "No Songs",
                    systemImage: "music.note",
                    message: searchText.isEmpty ? "No songs in your library." : "No results for “\(searchText)”."
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
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Songs")
        .searchable(text: $searchText, prompt: "Search in Songs")
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                debouncedSearchText = ""
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed
        }
        .onChange(of: query.isLoaded) { _, isLoaded in
            if isLoaded {
                previousSongs = query.value
                hasLoadedInitial = true
            }
        }
        .onChange(of: query.value) { _, newSongs in
            if query.isLoaded {
                previousSongs = newSongs
                hasLoadedInitial = true
            }
        }
        .onAppear {
            if query.isLoaded {
                previousSongs = query.value
                hasLoadedInitial = true
            }
        }
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Title").tag(SongSort.title)
                        Text("Artist").tag(SongSort.artist)
                        Text("Album").tag(SongSort.album)
                        Text("Year").tag(SongSort.year)
                        Text("Recently Added").tag(SongSort.recentlyAdded)
                        Text("Most Played").tag(SongSort.mostPlayed)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .observing(query)
    }
}
