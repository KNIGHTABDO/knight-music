import SwiftUI

/// Playlist detail screen matching Apple Music / Arpeggi.
struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var editMode: EditMode = .inactive
    @State private var showingRenameAlert = false
    @State private var newPlaylistName = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        let playlistQuery = library.playlist(id: playlistId)
        let songsQuery = library.playlistSongs(id: playlistId)
        let playlists = library.playlists()

        Group {
            if !playlistQuery.isLoaded {
                skeletonView
            } else if let playlist = playlistQuery.value {
                playlistContentView(playlist: playlist, songs: songsQuery.value)
            } else {
                EmptyStateView(
                    title: "Playlist Not Found",
                    systemImage: "music.note.list",
                    message: "This playlist is not available in your library."
                )
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await app.pullToRefresh() }
        .observing(playlistQuery)
        .observing(songsQuery)
        .observing(playlists)
    }

    // MARK: - Playlist Content

    private func playlistContentView(playlist: Playlist, songs: [Song]) -> some View {
        let items = songs.indices.map { PlaylistItem(id: "\($0)-\(songs[$0].id)", index: $0, song: songs[$0]) }

        return List {
            Section {
                headerView(playlist: playlist, songs: songs)
                    .listRowInsets(EdgeInsets(top: 12, leading: Theme.margin, bottom: 20, trailing: Theme.margin))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if songs.isEmpty {
                    Text("This playlist has no songs.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 24)
                } else {
                    ForEach(items) { item in
                        songRowView(song: item.song, index: item.index, songs: songs)
                            .listRowInsets(EdgeInsets(top: 6, leading: Theme.margin, bottom: 6, trailing: Theme.margin))
                            .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        Task {
                            do {
                                try await library.movePlaylistEntries(id: playlistId, from: source, to: destination)
                            } catch {
                                Log.sync.error("Move playlist entries failed: \(error)")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        Task {
                            do {
                                try await library.removeFromPlaylist(id: playlistId, indexes: Array(indexSet))
                            } catch {
                                Log.sync.error("Remove from playlist failed: \(error)")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .environment(\.editMode, $editMode)
        .toolbar {
            toolbarItems(playlist: playlist, songs: songs)
        }
        .alert("Rename Playlist", isPresented: $showingRenameAlert) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task {
                        do {
                            try await library.renamePlaylist(id: playlistId, name: trimmed)
                            ui.showToast("Playlist Renamed")
                        } catch {
                            Log.sync.error("Rename playlist failed: \(error)")
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Playlist",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    do {
                        try await library.deletePlaylist(id: playlistId)
                        ui.showToast("Playlist Deleted")
                        dismiss()
                    } catch {
                        Log.sync.error("Delete playlist failed: \(error)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete “\(playlist.name)”? This action cannot be undone.")
        }
    }

    // MARK: - Header

    private func headerView(playlist: Playlist, songs: [Song]) -> some View {
        Group {
            if sizeClass == .regular {
                HStack(alignment: .bottom, spacing: 24) {
                    PlaylistMosaic(coverArts: mosaicCovers(playlist: playlist, songs: songs), side: 240)

                    VStack(alignment: .leading, spacing: 6) {
                        playlistMetadata(playlist: playlist, songs: songs, alignment: .leading)
                        Spacer().frame(height: 12)
                        playbackButtons(songs: songs)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .center, spacing: 14) {
                    PlaylistMosaic(coverArts: mosaicCovers(playlist: playlist, songs: songs), side: 240)

                    playlistMetadata(playlist: playlist, songs: songs, alignment: .center)

                    playbackButtons(songs: songs)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func playlistMetadata(playlist: Playlist, songs: [Song], alignment: HorizontalAlignment) -> some View {
        let totalSeconds = songs.reduce(0.0) { $0 + $1.durationSeconds }

        return VStack(alignment: alignment, spacing: 4) {
            Text(playlist.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(alignment == .center ? .center : .leading)

            Text(KMFormat.songsAndDuration(count: songs.count, seconds: totalSeconds))
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryLabel)

            if let comment = playlist.comment, !comment.isEmpty {
                Text(comment)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }

            if let owner = playlist.owner, !owner.isEmpty {
                Text("Created by \(owner)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
        }
    }

    private func playbackButtons(songs: [Song]) -> some View {
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
    }

    // MARK: - Song Row

    private func songRowView(song: Song, index: Int, songs: [Song]) -> some View {
        let isPlaying = player.currentSong?.id == song.id
        let isPaused = isPlaying && !player.isPlaying
        let isDownloaded = downloads.isDownloaded(song.id)

        return Button {
            if editMode != .active {
                Haptics.selection()
                player.play(songs, startAt: index, shuffle: false)
            }
        } label: {
            SongRow(
                song: song,
                showsArtwork: true,
                isPlaying: isPlaying,
                isPaused: isPaused,
                isDownloaded: isDownloaded
            ) {
                SongActionsMenu(song: song)
                Divider()
                Button(role: .destructive) {
                    Task {
                        do {
                            try await library.removeFromPlaylist(id: playlistId, indexes: [index])
                        } catch {
                            Log.sync.error("Remove from playlist failed: \(error)")
                        }
                    }
                } label: {
                    Label("Remove from Playlist", systemImage: "trash")
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            SongActionsMenu(song: song)
            Divider()
            Button(role: .destructive) {
                Task {
                    do {
                        try await library.removeFromPlaylist(id: playlistId, indexes: [index])
                    } catch {
                        Log.sync.error("Remove from playlist failed: \(error)")
                    }
                }
            } label: {
                Label("Remove from Playlist", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarItems(playlist: Playlist, songs: [Song]) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(editMode == .active ? "Done" : "Edit") {
                withAnimation {
                    editMode = editMode == .active ? .inactive : .active
                }
            }

            Menu {
                Button {
                    newPlaylistName = playlist.name
                    showingRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    downloads.download(songs: songs)
                    ui.showToast("Downloading Playlist")
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle")
                }

                Divider()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    // MARK: - Helpers

    private func mosaicCovers(playlist: Playlist, songs: [Song]) -> [String?] {
        let covers = songs.prefix(4).map(\.coverArt)
        if covers.isEmpty {
            return [playlist.coverArt]
        }
        return covers
    }

    private var skeletonView: some View {
        ScrollView {
            VStack(spacing: 20) {
                LoadingShimmer(cornerRadius: 8)
                    .frame(width: 240, height: 240)
                    .padding(.top, 16)

                VStack(spacing: 8) {
                    LoadingShimmer(cornerRadius: 4).frame(width: 180, height: 20)
                    LoadingShimmer(cornerRadius: 4).frame(width: 130, height: 16)
                }

                SkeletonRowList(count: 6)
            }
        }
    }
}

private struct PlaylistItem: Identifiable {
    let id: String
    let index: Int
    let song: Song
}
