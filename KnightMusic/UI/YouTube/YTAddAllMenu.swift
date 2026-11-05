import SwiftUI

/// Toolbar menu on YouTube albums and playlists: add every song to Navidrome in one go.
struct YTAddAllMenu: View {
    let songs: [Song]

    @Environment(AppModel.self) private var app
    @Environment(UIState.self) private var ui
    @State private var isConfirming = false

    var body: some View {
        Menu {
            Button("Add All to Navidrome", systemImage: "square.and.arrow.down.on.square") {
                if songs.count > 10 { isConfirming = true } else { addAll() }
            }
            .disabled(songs.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .confirmationDialog("Add \(KMFormat.songCount(songs.count)) to Navidrome?", isPresented: $isConfirming,
                            titleVisibility: .visible) {
            Button("Add All") { addAll() }
        } message: {
            Text("Songs already in your library are skipped. Knight adds them one at a time.")
        }
    }

    private func addAll() {
        NavidromeImportCenter.shared.addAll(songs, app: app, ui: ui)
    }
}
