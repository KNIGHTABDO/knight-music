import SwiftUI

/// Action menu items for a song: used inside `.contextMenu { SongActionsMenu(song: song) }`
/// and inside `Menu { SongActionsMenu(song: song) } label: { … }` (the ••• button on rows).
/// Contains only Buttons, Menus, and Dividers with no surrounding layout.
struct SongActionsMenu: View {
    let song: Song

    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui

    var body: some View {
        let isStarred = song.starred != nil
        let isDownloaded = downloads.isDownloaded(song.id)
        let downloadStatus = downloads.status(for: song.id)
        let playlists = library.playlists()

        Button {
            player.enqueue([song], next: true)
            ui.showToast("Playing Next")
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            player.enqueue([song], next: false)
            ui.showToast("Added to Queue")
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Divider()

        Menu {
            if playlists.value.isEmpty {
                Text("No Playlists Available")
            } else {
                ForEach(playlists.value) { pl in
                    Button(pl.name) {
                        Task {
                            do {
                                try await library.addToPlaylist(id: pl.id, songIds: [song.id])
                                ui.showToast("Added to \(pl.name)")
                            } catch {
                                Log.sync.error("Add to playlist failed: \(error)")
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Add to a Playlist…", systemImage: "plus")
        }

        if isDownloaded {
            Button(role: .destructive) {
                downloads.delete(songIds: [song.id])
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else if downloadStatus?.state == .downloading || downloadStatus?.state == .queued {
            Button {
                downloads.cancel(songId: song.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                downloads.download(songs: [song])
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        Button {
            Haptics.impact(.light)
            Task {
                do {
                    try await library.setStarred(.song, id: song.id, !isStarred)
                } catch {
                    Log.sync.error("Set starred failed for \(song.id): \(error)")
                }
            }
        } label: {
            Label(isStarred ? "Unfavorite" : "Favorite", systemImage: isStarred ? "heart.slash" : "heart")
        }

        Menu {
            ForEach(1...5, id: \.self) { rating in
                Button {
                    Task {
                        do {
                            try await library.setRating(.song, id: song.id, rating: rating)
                        } catch {
                            Log.sync.error("Set rating failed for \(song.id): \(error)")
                        }
                    }
                } label: {
                    if (song.userRating ?? 0) == rating {
                        Label("\(rating) Star\(rating == 1 ? "" : "s")", systemImage: "checkmark")
                    } else {
                        Text("\(rating) Star\(rating == 1 ? "" : "s")")
                    }
                }
            }
            if (song.userRating ?? 0) > 0 {
                Divider()
                Button(role: .destructive) {
                    Task {
                        do {
                            try await library.setRating(.song, id: song.id, rating: 0)
                        } catch {
                            Log.sync.error("Clear rating failed for \(song.id): \(error)")
                        }
                    }
                } label: {
                    Label("Clear Rating", systemImage: "xmark")
                }
            }
        } label: {
            Label("Rate Song", systemImage: "star")
        }

        Divider()

        if let albumId = song.albumId, !albumId.isEmpty {
            NavigationLink(value: Route.album(albumId)) {
                Label("Go to Album", systemImage: "record.circle")
            }
        }

        if let artistId = song.artistId, !artistId.isEmpty {
            NavigationLink(value: Route.artist(artistId)) {
                Label("Go to Artist", systemImage: "person.crop.circle")
            }
        }

        Divider()

        ShareLink(item: "\(song.title) — \(song.artist ?? "")") {
            Label("Share Song", systemImage: "square.and.arrow.up")
        }
    }
}
