import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui
    @Environment(PlayerEngine.self) private var player
    @Environment(HermesService.self) private var hermes: HermesService?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @State private var playlistToDelete: Playlist?
    @State private var showDeleteConfirmation = false
    @State private var showSmartSheet = false
    @AppStorage("playlists.sort") private var sort: PlaylistSort = .name

    enum PlaylistSort: String, CaseIterable, Identifiable {
        case name = "Name"
        case recentlyUpdated = "Recently Updated"
        case recentlyCreated = "Recently Created"
        case songCount = "Most Songs"
        var id: String { rawValue }
    }

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
                    message: searchText.isEmpty ? "No playlists in your library." : "No results for “\(searchText)”.",
                    actionTitle: searchText.isEmpty ? "New Playlist" : nil,
                    action: {
                        newPlaylistName = ""
                        showCreateSheet = true
                    }
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
                                .contextMenu {
                                    Button {
                                        Task {
                                            let songs = (try? await library.playlistSongs(id: playlist.id).value) ?? []
                                            if !songs.isEmpty {
                                                player.play(songs, shuffle: false)
                                            }
                                        }
                                    } label: {
                                        Label("Play", systemImage: "play.fill")
                                    }
                                    Button {
                                        Task {
                                            let songs = (try? await library.playlistSongs(id: playlist.id).value) ?? []
                                            if !songs.isEmpty {
                                                player.play(songs, shuffle: true)
                                            }
                                        }
                                    } label: {
                                        Label("Shuffle", systemImage: "shuffle")
                                    }
                                    Divider()
                                    Button {
                                        duplicatePlaylist(playlist)
                                    } label: {
                                        Label("Duplicate to My Playlists", systemImage: "doc.on.doc")
                                    }
                                    if playlist.isOwned(by: library.currentUsername) {
                                        Divider()
                                        Button(role: .destructive) {
                                            playlistToDelete = playlist
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("Delete Playlist", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if playlist.isOwned(by: library.currentUsername) {
                                Button(role: .destructive) {
                                    playlistToDelete = playlist
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } else {
                                Button {
                                    duplicatePlaylist(playlist)
                                } label: {
                                    Label("Make Copy", systemImage: "doc.on.doc")
                                }
                                .tint(Theme.accent)
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

                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(PlaylistSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort Playlists")

                Menu {
                    Button {
                        newPlaylistName = ""
                        showCreateSheet = true
                    } label: {
                        Label("New Playlist", systemImage: "music.note.list")
                    }
                    Button {
                        showSmartSheet = true
                    } label: {
                        Label("New Smart Playlist", systemImage: "gearshape.2")
                    }
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
                                do {
                                    _ = try await library.createPlaylist(name: name)
                                    Haptics.success()
                                    ui.showToast("Playlist Created")
                                } catch {
                                    Log.sync.error("Create playlist failed: \(error)")
                                    Haptics.error()
                                    ui.showToast("Couldn't Create Playlist")
                                }
                            }
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(200)])
        }
        .sheet(isPresented: $showSmartSheet) {
            SmartPlaylistSheet()
        }
        .confirmationDialog(
            "Delete Playlist",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: playlistToDelete
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                Task {
                    do {
                        try await library.deletePlaylist(id: playlist.id)
                        Haptics.success()
                        ui.showToast("Playlist Deleted")
                    } catch {
                        Log.sync.error("Delete playlist failed: \(error)")
                        Haptics.error()
                        ui.showToast("Couldn't Delete Playlist")
                    }
                }
            }
        } message: { playlist in
            Text("Are you sure you want to delete “\(playlist.name)”?")
        }
        .observing(query)
    }

    private func duplicatePlaylist(_ playlist: Playlist) {
        Task {
            do {
                let copy = try await library.duplicatePlaylist(id: playlist.id)
                Haptics.success()
                ui.showToast("Created \"\(copy.name)\"")
            } catch {
                Haptics.error()
                ui.showToast("Could not duplicate playlist")
            }
        }
    }

    private func filtered(_ all: [Playlist]) -> [Playlist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        switch sort {
        case .name:
            return matched
        case .recentlyUpdated:
            return matched.sorted { ($0.changed ?? .distantPast) > ($1.changed ?? .distantPast) }
        case .recentlyCreated:
            return matched.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .songCount:
            return matched.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        }
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
