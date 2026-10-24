import SwiftUI

struct YTAlbumView: View {
    let browseId: String

    var body: some View {
        YTLoader(id: browseId, load: { [browseId] in try await YouTubeMusic.shared.album(browseId) }) { page in
            let songs = page.songs.map(\.song)
            let artist = page.artists.map(\.name).joined(separator: ", ")
            let detail = [page.subtitle, page.year.map(String.init), KMFormat.songCount(songs.count)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    YTCollectionHeader(title: page.title, subtitle: artist, subtitleRoute: page.artists.first?.route,
                                       detail: detail, thumbnail: page.thumbnail, songs: songs)
                        .padding(.horizontal, Theme.margin)
                        .padding(.top, 8)
                    YTSongList(songs: songs, numbered: true)
                    if let description = page.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(6)
                            .padding(.horizontal, Theme.margin)
                    }
                    if !page.otherVersions.isEmpty {
                        YTShelfView(shelf: YTShelf(title: "Other Versions", items: page.otherVersions.map(YTItem.album)))
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(page.title)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

struct YTPlaylistView: View {
    let browseId: String

    var body: some View {
        YTLoader(id: browseId, load: { [browseId] in try await YouTubeMusic.shared.playlist(browseId) }) { page in
            let songs = page.songs.map(\.song)
            let detail = [page.detail, KMFormat.songCount(songs.count)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    YTCollectionHeader(title: page.title, subtitle: page.subtitle, detail: detail,
                                       thumbnail: page.thumbnail, songs: songs)
                        .padding(.horizontal, Theme.margin)
                        .padding(.top, 8)
                    YTSongList(songs: songs)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(page.title)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

struct YTArtistView: View {
    let browseId: String

    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        YTLoader(id: browseId, load: { [browseId] in try await YouTubeMusic.shared.artist(browseId) }) { page in
            let topSongs = page.topSongs.map(\.song)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(page, topSongs: topSongs)
                    if !topSongs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionHeader(title: "Top Songs", route: page.topSongsMore?.songsRoute(title: "\(page.name) — Songs"))
                                .padding(.horizontal, Theme.margin)
                                .padding(.bottom, 6)
                            YTSongList(songs: topSongs)
                        }
                    }
                    ForEach(page.shelves) { shelf in
                        YTShelfView(shelf: shelf)
                    }
                    if let description = page.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "About")
                            Text(description)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondaryLabel)
                                .lineLimit(8)
                        }
                        .padding(.horizontal, Theme.margin)
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(page.name)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func header(_ page: YTArtistPage, topSongs: [Song]) -> some View {
        let size: CGFloat = sizeClass == .regular ? 220 : 180
        return VStack(spacing: 12) {
            ArtworkView(coverArt: page.thumbnail, pointSize: size, isCircle: true)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 9)
            Text(page.name)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(.center)
            if let subscribers = page.subscribers {
                Text(subscribers)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            HStack(spacing: 12) {
                Button {
                    Haptics.impact(.medium)
                    player.play(topSongs, shuffle: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.glass)
                .tint(Theme.accent)
                .disabled(topSongs.isEmpty)

                Button {
                    Haptics.impact(.medium)
                    if let seed = topSongs.first {
                        Task { await player.startStation(from: seed) }
                    }
                } label: {
                    Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.glass)
                .tint(Theme.accent)
                .disabled(topSongs.isEmpty)
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.margin)
        .padding(.top, 8)
    }
}

/// Everything behind a shelf's "More" (all albums, singles, related artists…).
struct YTGridView: View {
    let target: YTBrowseTarget
    let title: String

    var body: some View {
        YTLoader(id: target.browseId + (target.params ?? ""), load: { [target] in try await YouTubeMusic.shared.grid(target) }) { grid in
            ScrollView {
                AdaptiveAlbumGrid(items: grid.items) { item in
                    YTItemTile(item: item)
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// An artist's full song list.
struct YTSongsView: View {
    let target: YTBrowseTarget
    let title: String

    var body: some View {
        YTLoader(id: target.browseId + (target.params ?? ""), load: { [target] in try await YouTubeMusic.shared.songs(target) }) { songs in
            ScrollView {
                YTSongList(songs: songs.map(\.song))
                    .padding(.vertical, 12)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}
