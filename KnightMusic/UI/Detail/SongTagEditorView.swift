import SwiftUI

/// Edits the tags written in the song's file. Only fields that changed are sent; clearing one removes the tag.
struct SongTagEditorView: View {
    let song: Song
    var onSaved: (Song) -> Void

    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss

    @State private var fields: SongFileEditor.TagChanges
    @State private var saving = false
    @State private var failure: String?
    private let original: SongFileEditor.TagChanges

    init(song: Song, onSaved: @escaping (Song) -> Void) {
        self.song = song
        self.onSaved = onSaved
        let initial = SongFileEditor.TagChanges(
            title: song.title,
            artist: song.artist ?? "",
            album: song.album ?? "",
            albumArtist: "",
            year: song.year.map(String.init) ?? "",
            genre: song.genre ?? "",
            track: song.track.map(String.init) ?? "",
            disc: song.discNumber.map(String.init) ?? ""
        )
        original = initial
        _fields = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                field("Title", \.title)
                field("Artist", \.artist)
            }
            Section {
                field("Album", \.album)
                field("Album Artist", \.albumArtist, prompt: "Unchanged")
                field("Genre", \.genre)
            }
            Section {
                field("Year", \.year, numeric: true)
                field("Track", \.track, numeric: true)
                field("Disc", \.disc, numeric: true)
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(Theme.accent)
                } else {
                    Text("Saved into the music file on your server. Navidrome picks the change up within a few seconds.")
                }
            }
        }
        .navigationTitle("Edit Info")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save", systemImage: "checkmark", action: save)
                        .disabled(changes.isEmpty || (fields.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var changes: SongFileEditor.TagChanges {
        func changed(_ path: KeyPath<SongFileEditor.TagChanges, String?>) -> String? {
            let value = (fields[keyPath: path] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let old = (original[keyPath: path] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value == old ? nil : value
        }
        return SongFileEditor.TagChanges(
            title: changed(\.title), artist: changed(\.artist), album: changed(\.album),
            albumArtist: changed(\.albumArtist), year: changed(\.year), genre: changed(\.genre),
            track: changed(\.track), disc: changed(\.disc)
        )
    }

    private func field(
        _ title: String,
        _ path: WritableKeyPath<SongFileEditor.TagChanges, String?>,
        prompt: String? = nil,
        numeric: Bool = false
    ) -> some View {
        LabeledContent(title) {
            TextField(title, text: Binding(
                get: { fields[keyPath: path] ?? "" },
                set: { fields[keyPath: path] = numeric ? $0.filter(\.isNumber) : $0 }
            ), prompt: prompt.map { Text($0) })
            .multilineTextAlignment(.trailing)
            .keyboardType(numeric ? .numberPad : .default)
            .textInputAutocapitalization(numeric ? .never : .words)
            .autocorrectionDisabled()
        }
    }

    private func save() {
        let changes = changes
        saving = true
        failure = nil
        Task {
            do {
                let updated = try await library.editTags(of: song, changes)
                library.lastError = nil
                Haptics.success()
                onSaved(updated)
                ui.showToast("Saved")
                dismiss()
            } catch {
                library.lastError = nil
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
            saving = false
        }
    }
}
