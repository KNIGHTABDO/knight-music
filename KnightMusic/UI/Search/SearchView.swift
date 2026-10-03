import SwiftUI
import GRDB

struct SearchView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui: UIState?

    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var searchResults: SearchResults? = nil
    @State private var isSearching = false
    @State private var recentSearches: [String] = []

    var body: some View {
        ScrollView {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                emptyQueryView
            } else if let results = searchResults {
                if results.isEmpty && !isSearching {
                    EmptyStateView(
                        title: "No Results",
                        systemImage: "magnifyingglass",
                        message: "No results found for \u{201C}\(debouncedQuery)\u{201D}"
                    )
                    .padding(.top, 80)
                } else {
                    resultsView(results: results)
                }
            } else {
                SkeletonRowList(count: 6)
                    .padding(.top, 16)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search library...")
        .onSubmit(of: .search) {
            addRecentSearch(query)
        }
        .onAppear {
            loadRecentSearches()
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                debouncedQuery = ""
                searchResults = nil
                isSearching = false
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            debouncedQuery = trimmed
            isSearching = true

            if let db = library.database {
                let results = try? await db.pool.read { db in
                    try LibraryQueries.search(db, text: trimmed)
                }
                guard !Task.isCancelled else { return }
                if let results {
                    withAnimation(.smooth(duration: 0.2)) {
                        searchResults = results
                        isSearching = false
                    }
                }
            } else {
                let live = library.search(trimmed)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    searchResults = live.value
                    isSearching = false
                }
            }
        }
    }

    // MARK: - Empty Query State

    @ViewBuilder
    private var emptyQueryView: some View {
        VStack(spacing: 24) {
            EmptyStateView(
                title: "Search Library",
                systemImage: "magnifyingglass",
                message: "Search for artists, albums, or songs in your library."
            )
            .padding(.top, recentSearches.isEmpty ? 80 : 20)

            if !recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recently Searched")
                            .font(.kmSectionTitle)
                            .foregroundStyle(Theme.label)
                        Spacer()
                        Button("Clear") {
                            clearRecentSearches()
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, Theme.margin)

                    VStack(spacing: 0) {
                        ForEach(recentSearches, id: \.self) { term in
                            Button {
                                query = term
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Theme.secondaryLabel)
                                    Text(term)
                                        .font(.kmRowTitle)
                                        .foregroundStyle(Theme.label)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.tertiaryLabel)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, Theme.margin)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, Theme.margin + 28)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - Results View

    @ViewBuilder
    private func resultsView(results: SearchResults) -> some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if let hit = topHit {
                topHitSection(hit)
            }

            if !displayArtists.isEmpty {
                artistsSection(displayArtists)
            }

            if !displayAlbums.isEmpty {
                albumsSection(displayAlbums)
            }

            if !results.songs.isEmpty {
                songsSection(results.songs)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Top Hit Logic

    private enum TopHit {
        case artist(Artist)
        case album(Album)
    }

    private var topHit: TopHit? {
        guard let results = searchResults, !results.isEmpty else { return nil }
        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }

        if let artist = results.artists.first(where: { $0.name.lowercased() == q }) {
            return .artist(artist)
        }
        if let album = results.albums.first(where: { $0.name.lowercased() == q }) {
            return .album(album)
        }

        let artistPrefix = results.artists.first(where: { $0.name.lowercased().hasPrefix(q) })
        let albumPrefix = results.albums.first(where: { $0.name.lowercased().hasPrefix(q) })

        if let artistPrefix, let albumPrefix {
            let artistDiff = artistPrefix.name.count - q.count
            let albumDiff = albumPrefix.name.count - q.count
            return artistDiff <= albumDiff ? .artist(artistPrefix) : .album(albumPrefix)
        } else if let artistPrefix {
            return .artist(artistPrefix)
        } else if let albumPrefix {
            return .album(albumPrefix)
        }

        if let artist = results.artists.first, results.albums.isEmpty {
            return .artist(artist)
        }
        if let album = results.albums.first, results.artists.isEmpty {
            return .album(album)
        }
        if let artist = results.artists.first, let album = results.albums.first {
            if artist.name.lowercased().contains(q) && !album.name.lowercased().contains(q) {
                return .artist(artist)
            } else if album.name.lowercased().contains(q) && !artist.name.lowercased().contains(q) {
                return .album(album)
            } else if artist.name.lowercased().contains(q) {
                return .artist(artist)
            }
        }

        return nil
    }

    private var displayArtists: [Artist] {
        guard let results = searchResults else { return [] }
        if case .artist(let topArtist) = topHit {
            return Array(results.artists.filter { $0.id != topArtist.id }.prefix(8))
        }
        return Array(results.artists.prefix(8))
    }

    private var displayAlbums: [Album] {
        guard let results = searchResults else { return [] }
        if case .album(let topAlbum) = topHit {
            return results.albums.filter { $0.id != topAlbum.id }
        }
        return results.albums
    }

    // MARK: - Top Hit Section

    @ViewBuilder
    private func topHitSection(_ hit: TopHit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Top Result")
                .padding(.horizontal, Theme.margin)

            switch hit {
            case .artist(let artist):
                NavigationLink(value: Route.artist(artist.id)) {
                    HStack(spacing: 16) {
                        ArtworkView(coverArt: artist.coverArt, pointSize: 80, isCircle: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.name)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.label)
                                .lineLimit(2)
                            Text("Artist")
                                .font(.kmRowSubtitle)
                                .foregroundStyle(Theme.secondaryLabel)
                            if let count = artist.albumCount, count > 0 {
                                Text(KMFormat.albumCount(count))
                                    .font(.kmTileSubtitle)
                                    .foregroundStyle(Theme.tertiaryLabel)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryLabel)
                    }
                    .padding(14)
                    .background(Color(uiColor: .systemGray6).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.horizontal, Theme.margin)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    addRecentSearch(debouncedQuery)
                })

            case .album(let album):
                NavigationLink(value: Route.album(album.id)) {
                    HStack(spacing: 16) {
                        ArtworkView(coverArt: album.coverArt, pointSize: 80, cornerRadius: Theme.Radius.tile)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(album.name)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.label)
                                .lineLimit(2)
                            if let artist = album.artist {
                                Text(artist)
                                    .font(.kmRowSubtitle)
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }
                            Text("Album" + (album.year.map { " • \($0)" } ?? ""))
                                .font(.kmTileSubtitle)
                                .foregroundStyle(Theme.tertiaryLabel)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryLabel)
                    }
                    .padding(14)
                    .background(Color(uiColor: .systemGray6).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.horizontal, Theme.margin)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    AlbumContextMenu(album: album)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    addRecentSearch(debouncedQuery)
                })
            }
        }
    }

    // MARK: - Artists Section

    @ViewBuilder
    private func artistsSection(_ artists: [Artist]) -> some View {
        ShelfSection(title: "Artists", items: artists) { artist in
            NavigationLink(value: Route.artist(artist.id)) {
                AlbumTile(coverArt: artist.coverArt, title: artist.name, subtitle: "Artist", isCircle: true)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                addRecentSearch(debouncedQuery)
            })
        }
    }

    // MARK: - Albums Section

    @ViewBuilder
    private func albumsSection(_ albums: [Album]) -> some View {
        ShelfSection(title: "Albums", items: albums) { album in
            NavigationLink(value: Route.album(album.id)) {
                AlbumTile(album: album)
            }
            .buttonStyle(.plain)
            .contextMenu {
                AlbumContextMenu(album: album)
            }
            .simultaneousGesture(TapGesture().onEnded {
                addRecentSearch(debouncedQuery)
            })
        }
    }

    // MARK: - Songs Section

    @ViewBuilder
    private func songsSection(_ songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Songs")
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 6)

            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                Button {
                    Haptics.impact(.medium)
                    player.play(songs, startAt: index, shuffle: false)
                    addRecentSearch(debouncedQuery)
                } label: {
                    SongRow(
                        song: song,
                        showsArtwork: true,
                        isPlaying: player.currentSong?.id == song.id,
                        isPaused: !player.isPlaying,
                        isDownloaded: downloads.isDownloaded(song.id)
                    ) {
                        SongActionsMenu(song: song)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, Theme.margin)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    SongActionsMenu(song: song)
                }

                if index < songs.count - 1 {
                    Divider().padding(.leading, 76)
                }
            }
        }
    }

    // MARK: - Recent Searches Persistence

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: "recent_searches") ?? []
    }

    private func addRecentSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        current.insert(trimmed, at: 0)
        if current.count > 10 {
            current = Array(current.prefix(10))
        }
        recentSearches = current
        UserDefaults.standard.set(current, forKey: "recent_searches")
    }

    private func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recent_searches")
    }
}
