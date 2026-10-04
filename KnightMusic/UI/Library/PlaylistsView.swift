import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui
    @Environment(HermesService.self) private var hermes: HermesService?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @State private var playlistToDelete: Playlist?
    @State private var showDeleteConfirmation = false

    var body: some View {
        let query = library.playlists()
        let playlists = filtered(query.value)

        Group {
            if !query.isLoaded {
                List {
                    SkeletonRowList(count: 8)
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if playlists.isEmpty {
                EmptyStateView(
                    title: "No Playlists",
                    systemImage: "music.note.list",
                    message: searchText.isEmpty ? "No playlists in your library." : "No results for “\(searchText)”."
                )
            } else {
                List {
                    ForEach(playlists) { playlist in
                        ZStack {
                            NavigationLink(value: Route.playlist(playlist.id)) {
                                EmptyView()
                            }
                            .opacity(0)

                            PlaylistRowItem(playlist: playlist)
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                playlistToDelete = playlist
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Playlists")
        .searchable(text: $searchText, prompt: "Search in Playlists")
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if hermes?.settings.isConfigured == true {
                    Button {
                        ui.askKnight("Make me a playlist of ")
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Ask Knight for a playlist")
                    .help("Ask Knight for a playlist")
                }

                Button {
                    newPlaylistName = ""
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel("Create Playlist")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Playlist Name", text: $newPlaylistName)
                            .textInputAutocapitalization(.words)
                    }
                }
                .navigationTitle("New Playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showCreateSheet = false
                            newPlaylistName = ""
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                            showCreateSheet = false
                            newPlaylistName = ""
                            Task {
                                try? await library.createPlaylist(name: name)
                            }
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(200)])
        }
        .confirmationDialog(
            "Delete Playlist",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: playlistToDelete
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                Task {
                    try? await library.deletePlaylist(id: playlist.id)
                }
            }
        } message: { playlist in
            Text("Are you sure you want to delete “\(playlist.name)”?")
        }
        .observing(query)
    }

    private func filtered(_ all: [Playlist]) -> [Playlist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}

private struct PlaylistRowItem: View {
    let playlist: Playlist
    @Environment(LibraryRepository.self) private var library

    var body: some View {
        let songsQuery = library.playlistSongs(id: playlist.id)
        let covers = resolveCoverArts(from: songsQuery.value)

        PlaylistRow(
            name: playlist.name,
            coverArts: covers,
            songCount: playlist.songCount ?? songsQuery.value.count,
            duration: TimeInterval(playlist.duration ?? 0)
        )
        .padding(.vertical, 4)
        .observing(songsQuery)
    }

    private func resolveCoverArts(from songs: [Song]) -> [String?] {
        let songCovers = songs.compactMap(\.coverArt)
        if songCovers.count >= 4 {
            return Array(songCovers.prefix(4))
        }
        if let art = playlist.coverArt, !art.isEmpty {
            return [art]
        }
        return songCovers
    }
}
