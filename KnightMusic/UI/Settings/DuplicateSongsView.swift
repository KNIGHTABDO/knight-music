import SwiftUI

/// Songs stored more than once. The best copy of each group is kept by default; the others are pre-selected and move
/// to the library's .trash/songs folder on the server (move a file back to restore it).
struct DuplicateSongsView: View {
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui

    @State private var groups: [[Song]]?
    @State private var selected = Set<String>()
    @State private var confirming = false
    @State private var removing = false
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(Theme.accent) }
            }
            ForEach(groups ?? [], id: \.first?.id) { group in
                Section {
                    ForEach(group) { song in
                        row(song, best: song.id == group.first?.id)
                    }
                } header: {
                    Text("\(group[0].title) · \(group[0].artist ?? "Unknown Artist")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if groups == nil {
                ProgressView()
            } else if groups?.isEmpty == true {
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle",
                                       description: Text("Every song in your library is stored once."))
            }
        }
        .navigationTitle("Duplicate Songs")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if removing {
                    ProgressView()
                } else if !selected.isEmpty {
                    Button("Remove \(selected.count)", role: .destructive) { confirming = true }
                }
            }
        }
        .confirmationDialog(
            "Remove \(selected.count) \(selected.count == 1 ? "copy" : "copies")?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive, action: remove)
        } message: {
            Text("The files move to .trash/songs in your music folder on the server. Move them back to restore them.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ song: Song, best: Bool) -> some View {
        Button {
            if selected.contains(song.id) { selected.remove(song.id) } else { selected.insert(song.id) }
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(song.id) ? "trash.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected.contains(song.id) ? Theme.accent : Theme.secondaryLabel)
                ArtworkView(coverArt: song.coverArt, pointSize: 44, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(song.album ?? "No Album").font(.kmRowTitle).foregroundStyle(Theme.label).lineLimit(1)
                        if best {
                            Text("Best").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(details(song)).font(.footnote).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
                    if let path = song.path {
                        Text(path).font(.caption2.monospaced()).foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .contextMenu { SongActionsMenu(song: song) }
        .accessibilityAddTraits(selected.contains(song.id) ? .isSelected : [])
    }

    private func details(_ song: Song) -> String {
        [song.suffix?.uppercased(), AudioFormatText.bitRate(song.bitRate),
         song.duration.map { KMFormat.duration(TimeInterval($0)) },
         song.playCount.flatMap { $0 > 0 ? "\($0) plays" : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        let found = await library.duplicateSongGroups()
        groups = found
        selected = Set(found.flatMap { $0.dropFirst().map(\.id) })
    }

    private func remove() {
        let songs = (groups ?? []).flatMap { $0 }.filter { selected.contains($0.id) }
        removing = true
        failure = nil
        Task {
            do {
                let count = try await library.trashSongFiles(songs)
                Haptics.success()
                ui.showToast("Moved \(count) to Trash")
            } catch {
                library.lastError = nil
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
            removing = false
            await load()
        }
    }
}
