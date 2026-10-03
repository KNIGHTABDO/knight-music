import SwiftUI
import GRDB

struct LetterSection<T: Identifiable>: Identifiable {
    let letter: String
    let items: [T]
    var id: String { letter }
}

enum Sectioning {
    /// Groups items into letter sections: "#" for symbols, digits, non-Latin, then "A"..."Z".
    static func byFirstLetter<T: Identifiable>(
        _ items: [T],
        letterFor: (T) -> String
    ) -> [LetterSection<T>] {
        var grouped: [String: [T]] = [:]
        for item in items {
            let key = normalizeLetter(letterFor(item))
            grouped[key, default: []].append(item)
        }

        let allKeys = grouped.keys
        let latinKeys = allKeys.filter { $0 != "#" }.sorted()
        var orderedKeys: [String] = []
        if grouped["#"] != nil {
            orderedKeys.append("#")
        }
        orderedKeys.append(contentsOf: latinKeys)

        return orderedKeys.map { key in
            LetterSection(letter: key, items: grouped[key] ?? [])
        }
    }

    static func normalizeLetter(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let s = String(first).uppercased()
        if let scalar = s.unicodeScalars.first, scalar.value >= 65 && scalar.value <= 90 {
            return s
        }
        return "#"
    }

    static func scrollToLetter<T: Identifiable>(_ letter: String, sections: [LetterSection<T>], proxy: ScrollViewProxy) {
        if sections.contains(where: { $0.letter == letter }) {
            withAnimation(.snappy(duration: 0.2)) {
                proxy.scrollTo(letter, anchor: .top)
            }
            return
        }
        if letter != "#" {
            if let nextSection = sections.first(where: { $0.letter > letter }) {
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(nextSection.letter, anchor: .top)
                }
            } else if let last = sections.last {
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(last.letter, anchor: .top)
                }
            }
        } else if let first = sections.first {
            withAnimation(.snappy(duration: 0.2)) {
                proxy.scrollTo(first.letter, anchor: .top)
            }
        }
    }
}

@MainActor
enum ArtistPlaybackHelper {
    static func playArtistSongs(artist: Artist, library: LibraryRepository, player: PlayerEngine, shuffle: Bool) {
        Task {
            guard let db = library.database else { return }
            let songs = (try? await db.pool.read { db in
                try LibraryQueries.songs(db, artistId: artist.id)
            }) ?? []
            guard !songs.isEmpty else { return }
            player.play(songs, shuffle: shuffle)
        }
    }
}

struct AlbumContextMenu: View {
    let album: Album
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui

    var body: some View {
        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.play(content.songs, shuffle: false)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.play(content.songs, shuffle: true)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.enqueue(content.songs, next: true)
                ui.showToast("Playing next: \(album.name)")
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                player.enqueue(content.songs, next: false)
                ui.showToast("Added to queue: \(album.name)")
            }
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Button {
            Task {
                let content = await library.albumContent(id: album.id)
                guard !content.songs.isEmpty else { return }
                downloads.download(songs: content.songs)
                ui.showToast("Downloading \(album.name)")
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }

        Button {
            Task {
                let isStarred = album.starred != nil
                try? await library.toggleStar(.album, id: album.id, currentlyStarred: isStarred)
                Haptics.impact(.medium)
            }
        } label: {
            Label(album.starred != nil ? "Unfavorite" : "Favorite",
                  systemImage: album.starred != nil ? "heart.slash" : "heart")
        }
    }
}

struct ArtistContextMenu: View {
    let artist: Artist
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Button {
            ArtistPlaybackHelper.playArtistSongs(artist: artist, library: library, player: player, shuffle: false)
        } label: {
            Label("Play All", systemImage: "play.fill")
        }

        Button {
            ArtistPlaybackHelper.playArtistSongs(artist: artist, library: library, player: player, shuffle: true)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            Task {
                let isStarred = artist.starred != nil
                try? await library.toggleStar(.artist, id: artist.id, currentlyStarred: isStarred)
                Haptics.impact(.medium)
            }
        } label: {
            Label(artist.starred != nil ? "Unfavorite" : "Favorite",
                  systemImage: artist.starred != nil ? "heart.slash" : "heart")
        }
    }
}
