import SwiftUI

/// Context menu actions for an album tile:
/// Play, Shuffle, Play Next, Add to Queue, Download, Favorite/Unfavorite.
struct AlbumContextMenu: View {
    let album: Album

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui: UIState?

    var body: some View {
        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.play(content.songs, startAt: 0, shuffle: false)
                Haptics.impact(.medium)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.play(content.songs, shuffle: true)
                Haptics.impact(.medium)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.enqueue(content.songs, next: true)
                ui?.showToast("Playing next: \(album.name)")
                Haptics.impact(.light)
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.enqueue(content.songs, next: false)
                ui?.showToast("Added to queue")
                Haptics.impact(.light)
            }
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                downloads.download(songs: content.songs)
                ui?.showToast("Downloading \(album.name)")
                Haptics.impact(.light)
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }

        let isStarred = album.starred != nil
        Button {
            Task {
                Haptics.impact(.light)
                try? await library.setStarred(.album, id: album.id, !isStarred)
            }
        } label: {
            Label(isStarred ? "Unfavorite" : "Favorite", systemImage: isStarred ? "heart.slash" : "heart")
        }
    }
}
