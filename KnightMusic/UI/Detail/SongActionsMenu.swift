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
    @Environment(AppModel.self) private var app

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

        Button {
            Haptics.impact(.light)
            Task { await player.startStation(from: song) }
        } label: {
            Label("Start Station", systemImage: "dot.radiowaves.left.and.right")
        }

        if song.isYouTube {
            youTubeActions
        } else {
            libraryActions(isStarred: isStarred, isDownloaded: isDownloaded, downloadStatus: downloadStatus, playlists: playlists.value)
        }
    }

    @ViewBuilder private var youTubeActions: some View {
        Divider()

        Button {
            NavidromeImportCenter.shared.add(song, app: app, ui: ui)
        } label: {
            Label("Add to Navidrome", systemImage: "plus.circle")
        }

        Divider()

        navigationActions

        if let videoId = song.youTubeVideoId, let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)") {
            ShareLink(item: url) {
                Label("Share Song", systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder private var navigationActions: some View {
        if let albumId = song.albumId, !albumId.isEmpty {
            Button {
                ui.open(.album(albumId))
            } label: {
                Label("Go to Album", systemImage: "record.circle")
            }
        }

        if let artistId = song.artistId, !artistId.isEmpty {
            Button {
                ui.open(.artist(artistId))
            } label: {
                Label("Go to Artist", systemImage: "person.crop.circle")
            }
        }
    }

    @ViewBuilder
    private func libraryActions(isStarred: Bool, isDownloaded: Bool, downloadStatus: DownloadStatus?, playlists: [Playlist]) -> some View {
        Divider()

        Menu {
            Button {
                ui.playlistPicker = PlaylistPickerRequest(songs: [song])
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
            if !playlists.isEmpty {
                Divider()
                ForEach(playlists) { pl in
                    Button(pl.name) {
                        Task {
                            if (try? await library.addToPlaylist(id: pl.id, songIds: [song.id])) != nil {
                                ui.showToast("Added to \(pl.name)")
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
                try? await library.setStarred(.song, id: song.id, !isStarred)
            }
        } label: {
            Label(isStarred ? "Unfavorite" : "Favorite", systemImage: isStarred ? "heart.slash" : "heart")
        }

        Menu {
            ForEach(1...5, id: \.self) { rating in
                Button {
                    Task {
                        try? await library.setRating(.song, id: song.id, rating: rating)
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
                        try? await library.setRating(.song, id: song.id, rating: 0)
                    }
                } label: {
                    Label("Clear Rating", systemImage: "xmark")
                }
            }
        } label: {
            Label("Rate Song", systemImage: "star")
        }

        Divider()

        navigationActions

        Button {
            ui.songInfo = song
        } label: {
            Label("Song Info", systemImage: "info.circle")
        }

        Divider()

        ShareLink(item: "\(song.title) — \(song.artist ?? "")") {
            Label("Share Song", systemImage: "square.and.arrow.up")
        }
    }
}
