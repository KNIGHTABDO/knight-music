import SwiftUI

/// Songs waiting to be added to a playlist (from a multi-selection, the queue, or a menu).
struct PlaylistPickerRequest: Identifiable {
    let id = UUID()
    var songs: [Song]
    /// Pre-filled name for "New Playlist" (e.g. when saving the queue).
    var suggestedName: String = ""
}

/// "Add to Playlist" sheet: a new playlist or any existing one (2x2 collages), works for many songs at once.
struct PlaylistPickerSheet: View {
    let request: PlaylistPickerRequest

    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var isCreating = false
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let playlists = library.playlists()
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

                if !playlists.value.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists.value) { playlist in
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
            }
            .navigationTitle(request.songs.count == 1 ? "Add to Playlist" : "Add \(request.songs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .overlay { if isSaving { ProgressView() } }
        }
        .observing(playlists)
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
            if (try? await library.addToPlaylist(id: playlist.id, songIds: request.songs.map(\.id))) != nil {
                Haptics.success()
                ui.showToast("Added to \(playlist.name)")
                dismiss()
            }
        }
    }
}
