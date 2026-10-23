import SwiftUI

/// Standard swipe actions for a song row inside a `List`: leading Play Next / Add to Queue,
/// trailing Love / Download (or Remove Download).
struct SongSwipeActions: ViewModifier {
    let song: Song
    /// Off where the list owns the trailing edge (e.g. `.onDelete` in a playlist); any trailing
    /// `.swipeActions` would replace the system delete action.
    var trailing = true

    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui: UIState?

    func body(content: Content) -> some View {
        let leading = content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Haptics.impact(.light)
                    player.enqueue([song], next: true)
                    ui?.showToast("Playing Next")
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(Theme.accent)

                Button {
                    Haptics.impact(.light)
                    player.enqueue([song], next: false)
                    ui?.showToast("Added to Queue")
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                .tint(.orange)
            }
        if trailing {
            leading.swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingActions }
        } else {
            leading
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        let isStarred = song.starred != nil
        Button {
            Haptics.impact(.medium)
            Task {
                try? await library.toggleStar(.song, id: song.id, currentlyStarred: isStarred)
            }
        } label: {
            Label(isStarred ? "Unlove" : "Love", systemImage: isStarred ? "heart.slash" : "heart")
        }
        .tint(.pink)

        if downloads.isDownloaded(song.id) {
            Button(role: .destructive) {
                downloads.delete(songIds: [song.id])
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else {
            Button {
                Haptics.impact(.light)
                downloads.download(songs: [song])
                ui?.showToast("Downloading")
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(.blue)
        }
    }
}

extension View {
    func songSwipeActions(_ song: Song, trailing: Bool = true) -> some View {
        modifier(SongSwipeActions(song: song, trailing: trailing))
    }
}
