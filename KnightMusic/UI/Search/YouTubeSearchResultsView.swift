import SwiftUI

/// Search results from YouTube Music for the Search tab's "YouTube Music" source.
struct YouTubeSearchResultsView: View {
    let query: String
    @Binding var scope: SearchView.SearchScope

    @Environment(PlayerEngine.self) private var player

    @State private var results: YTSearchResults?
    @State private var resultsQuery = ""
    @State private var errorMessage: String?
    @State private var notice: String?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding(.horizontal, Theme.margin)
            }
            if let errorMessage {
                EmptyStateView(title: "YouTube Music Unavailable", systemImage: "exclamationmark.triangle",
                               message: errorMessage, actionTitle: "Try Again") {
                    self.errorMessage = nil
                    resultsQuery = ""
                    Task { await search() }
                }
                .padding(.top, 60)
            } else if let results, resultsQuery == query {
                if results.isEmpty {
                    EmptyStateView(title: "No Results", systemImage: "magnifyingglass",
                                   message: "YouTube Music has nothing for \u{201C}\(query)\u{201D}")
                        .padding(.top, 60)
                } else {
                    sections(results)
                }
            } else {
                SkeletonRowList(count: 6)
            }
        }
        .padding(.vertical, 16)
        .animation(.smooth(duration: 0.2), value: scope)
        .task(id: query) { await search() }
    }

    @ViewBuilder
    private func sections(_ results: YTSearchResults) -> some View {
        switch scope {
        case .top:
            if !results.songs.isEmpty {
                songs(Array(results.songs.prefix(6)), title: "Songs", showsMore: results.songs.count > 6)
            }
            if !results.artists.isEmpty {
                YTShelfView(shelf: YTShelf(title: "Artists", items: results.artists.map(YTItem.artist)))
            }
            if !results.albums.isEmpty {
                YTShelfView(shelf: YTShelf(title: "Albums", items: results.albums.map(YTItem.album)))
            }
            if !results.videos.isEmpty {
                YTShelfView(shelf: YTShelf(title: "Videos", items: results.videos.map(YTItem.song)))
            }
            if !results.playlists.isEmpty {
                YTShelfView(shelf: YTShelf(title: "Playlists", items: results.playlists.map(YTItem.playlist)))
            }
        case .songs:
            songs(results.songs + results.videos, title: nil, showsMore: false)
        case .artists:
            VStack(spacing: 0) {
                ForEach(results.artists) { artist in
                    NavigationLink(value: Route.artist(Song.youTubePrefix + artist.browseId)) {
                        ArtistRow(name: artist.name, coverArt: artist.thumbnail, subtitle: artist.subtitle)
                            .padding(.horizontal, Theme.margin)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, Theme.margin + 68)
                }
            }
        case .albums:
            AdaptiveAlbumGrid(items: results.albums.map(YTItem.album)) { YTItemTile(item: $0) }
        case .playlists:
            AdaptiveAlbumGrid(items: results.playlists.map(YTItem.playlist)) { YTItemTile(item: $0) }
        }
    }

    private func songs(_ songs: [YTSong], title: String?, showsMore: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                SectionHeader(title: title, action: showsMore ? { scope = .songs } : nil)
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 6)
            }
            YTSongList(songs: songs.map(\.song))
        }
    }

    private func search() async {
        let text = query
        guard !text.isEmpty, resultsQuery != text || results == nil else { return }
        let config = await YouTubeConfigStore.shared.current()
        notice = config.message
        do {
            let found = try await YouTubeMusic.shared.search(text)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) {
                results = found
                resultsQuery = text
                errorMessage = nil
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            Log.api.warning("YouTube Music search failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}
