import SwiftUI

/// Songs waiting to be added to a playlist (from a multi-selection, the queue, or a menu).
struct PlaylistPickerRequest: Identifiable {
    let id = UUID()
    var songs: [Song]
    /// Pre-filled name for "New Playlist" (e.g. when saving the queue).
    var suggestedName: String = ""
    var targetPlaylist: Playlist? = nil
    var createNew = false
}

/// "Add to Playlist" sheet: a new playlist or any existing one (2x2 collages), works for many songs at once.
struct PlaylistPickerSheet: View {
    let request: PlaylistPickerRequest

    @Environment(LibraryRepository.self) private var library
    @Environment(AppModel.self) private var app
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var isCreating = false
    @State private var isSaving = false
    @State private var playlistToFork: Playlist?
    @State private var showForkAlert = false
    @State private var didApplyRequest = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let playlists = library.playlists()
        let currentUsername = library.currentUsername
        let ownedPlaylists = playlists.value.filter { $0.isOwned(by: currentUsername) }
        let sharedPlaylists = playlists.value.filter { !$0.isOwned(by: currentUsername) }

        NavigationStack {
            List {
                Section {
                    if isCreating {
                        HStack {
                            TextField("Playlist Name", text: $newName)
                                .focused($nameFocused)
                                .submitLabel(.done)
                                .onSubmit(create)
                            Button("Create", action: create)
                                .buttonStyle(.glassProminent)
                                .disabled(trimmedName.isEmpty || isSaving)
                        }
                    } else {
                        Button {
                            newName = request.suggestedName
                            withAnimation(.snappy) { isCreating = true }
                            nameFocused = true
                        } label: {
                            Label("New Playlist…", systemImage: "plus")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }

                if !ownedPlaylists.isEmpty {
                    Section(sharedPlaylists.isEmpty ? "Playlists" : "My Playlists") {
                        ForEach(ownedPlaylists) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                HStack(spacing: 12) {
                                    PlaylistMosaic(coverArts: [playlist.coverArt], side: 48)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name).font(.kmRowTitle).foregroundStyle(Theme.label)
                                        Text(KMFormat.songCount(playlist.songCount ?? 0))
                                            .font(.kmRowSubtitle).foregroundStyle(Theme.secondaryLabel)
                                    }
                                }
                            }
                            .disabled(isSaving)
                        }
                    }
                }

                if !sharedPlaylists.isEmpty {
                    Section("Shared & Smart Playlists") {
                        ForEach(sharedPlaylists) { playlist in
                            Button {
                                playlistToFork = playlist
                                showForkAlert = true
                            } label: {
                                HStack(spacing: 12) {
                                    PlaylistMosaic(coverArts: [playlist.coverArt], side: 48)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(playlist.name).font(.kmRowTitle).foregroundStyle(Theme.label)
                                            Image(systemName: "person.2.fill")
                                                .font(.caption2)
                                                .foregroundStyle(Theme.secondaryLabel)
                                        }
                                        Text(KMFormat.songCount(playlist.songCount ?? 0) + (playlist.owner.map { " • \($0)" } ?? ""))
                                            .font(.kmRowSubtitle).foregroundStyle(Theme.secondaryLabel)
                                    }
                                    Spacer()
                                    Text("Make Copy")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .disabled(isSaving)
                        }
                    }
                }
            }
            .navigationTitle(request.songs.count == 1 ? "Add to Playlist" : "Add \(request.songs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .alert("Shared Playlist", isPresented: $showForkAlert, presenting: playlistToFork) { playlist in
                Button("Create Copy & Add") {
                    duplicateAndAdd(to: playlist)
                }
                Button("Cancel", role: .cancel) {}
            } message: { playlist in
                Text("'\(playlist.name)' is managed by the server or shared by another user. Create your own editable copy with \(request.songs.count == 1 ? "this song" : "these songs") added?")
            }
            .overlay { if isSaving { ProgressView() } }
        }
        .observing(playlists)
        .onChange(of: app.activeAccount?.id) { _, _ in dismiss() }
        .task {
            guard !didApplyRequest else { return }
            didApplyRequest = true
            if let target = request.targetPlaylist {
                if target.isOwned(by: library.currentUsername) {
                    add(to: target)
                } else {
                    playlistToFork = target
                    showForkAlert = true
                }
            } else if request.createNew {
                newName = request.suggestedName
                isCreating = true
                nameFocused = true
            }
        }
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            if (try? await library.createPlaylist(name: name, songIds: request.songs.map(\.id))) != nil {
                Haptics.success()
                ui.showToast("Created \(name)")
                dismiss()
            }
        }
    }

    private func add(to playlist: Playlist) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await library.addToPlaylist(id: playlist.id, songIds: request.songs.map(\.id))
                Haptics.success()
                ui.showToast("Added to \(playlist.name)")
                dismiss()
            } catch LibraryRepository.PlaylistEditError.notOwner(let p) {
                playlistToFork = p
                showForkAlert = true
            } catch {
                // Handled in repository
            }
        }
    }

    private func duplicateAndAdd(to playlist: Playlist) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let copy = try await library.duplicatePlaylist(id: playlist.id, additionalSongIds: request.songs.map(\.id))
                Haptics.success()
                ui.showToast("Created '\(copy.name)'")
                dismiss()
            } catch {
                ui.showToast("Could not duplicate playlist")
            }
        }
    }
}
