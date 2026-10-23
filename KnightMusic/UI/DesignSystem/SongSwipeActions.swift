import SwiftUI

/// Standard swipe actions for a song row inside a `List`: leading Play Next / Add to Queue,
/// trailing Download (or Remove Download) / Love.
struct SongSwipeActions: ViewModifier {
    let song: Song

    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui: UIState?

    func body(content: Content) -> some View {
        let isStarred = song.starred != nil
        let isDownloaded = downloads.isDownloaded(song.id)
        content
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    Haptics.impact(.medium)
                    Task {
                        do {
                            try await library.toggleStar(.song, id: song.id, currentlyStarred: isStarred)
                        } catch {
                            library.report(error, "Couldn’t update favorite")
                        }
                    }
                } label: {
                    Label(isStarred ? "Unlove" : "Love", systemImage: isStarred ? "heart.slash" : "heart")
                }
                .tint(.pink)

                if isDownloaded {
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
}

extension View {
    func songSwipeActions(_ song: Song) -> some View {
        modifier(SongSwipeActions(song: song))
    }
}
