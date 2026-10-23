import SwiftUI

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var sortOrder: AlbumSort = .name
    @State private var hasLoadedInitial = false
    @State private var previousAlbums: [Album] = []
    @AppStorage("albums.layout") private var layout: LibraryLayout = .grid
    @AppStorage("albums.favoritesOnly") private var favoritesOnly = false
    @AppStorage("albums.descending") private var descending = false

    private var hasLetterSections: Bool {
        sortOrder == .name || sortOrder == .artist
    }

    var body: some View {
        let query = library.albums(sort: sortOrder, search: debouncedSearchText)
        let loaded = query.isLoaded ? query.value : (hasLoadedInitial ? previousAlbums : query.value)
        let albums = refine(loaded)
        let sections = descending ? Array(letterSections(from: albums).reversed()) : letterSections(from: albums)
        let showSkeleton = !query.isLoaded && !hasLoadedInitial

        let isScrubberVisible = hasLetterSections && sections.count > 1 && (query.isLoaded || hasLoadedInitial)

        ScrollViewReader { proxy in
            ScrollView {
                if showSkeleton {
                    SkeletonTileGrid()
                        .padding(.vertical, Theme.margin)
                } else if albums.isEmpty {
                    EmptyStateView(
                        title: "No Albums",
                        systemImage: "square.stack",
                        message: emptyMessage,
                        actionTitle: favoritesOnly ? "Show All Albums" : (searchText.isEmpty ? "Sync Now" : nil),
                        action: {
                            if favoritesOnly {
                                favoritesOnly = false
                            } else {
                                Task { await app.pullToRefresh() }
                            }
                        }
                    )
                    .padding(.top, 60)
                } else if hasLetterSections {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                items(section.items)
                                    .padding(.trailing, isScrubberVisible ? 22 : 0)
                            } header: {
                                LetterHeader(letter: section.letter)
                                    .id(section.letter)
                            }
                        }
                    }
                    .padding(.bottom, Theme.margin)
                } else {
                    items(albums)
                        .padding(.trailing, isScrubberVisible ? 22 : 0)
                        .padding(.vertical, Theme.margin)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                if isScrubberVisible {
                    AlphabetIndexScrubber(
                        activeLetters: Set(sections.map(\.letter))
                    ) { letter in
                        Sectioning.scrollToLetter(letter, sections: sections, proxy: proxy)
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Search in Albums...")
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                debouncedSearchText = ""
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed
        }
        .onChange(of: query.isLoaded) { _, isLoaded in
            if isLoaded {
                previousAlbums = query.value
                hasLoadedInitial = true
            }
        }
        .onChange(of: query.value) { _, newAlbums in
            if query.isLoaded {
                previousAlbums = newAlbums
                hasLoadedInitial = true
            }
        }
        .onAppear {
            if query.isLoaded {
                previousAlbums = query.value
                hasLoadedInitial = true
            }
        }
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Layout", selection: $layout) {
                        ForEach(LibraryLayout.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.palette)
                    Section("Sort By") {
                        Picker("Sort", selection: $sortOrder) {
                            Text("Name").tag(AlbumSort.name)
                            Text("Artist").tag(AlbumSort.artist)
                            Text("Year").tag(AlbumSort.year)
                            Text("Recently Added").tag(AlbumSort.recentlyAdded)
                            Text("Most Played").tag(AlbumSort.mostPlayed)
                            Text("Recently Played").tag(AlbumSort.recentlyPlayed)
                        }
                        Toggle(isOn: $descending) {
                            Label("Reverse Order", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    Section("Filter") {
                        Toggle(isOn: $favoritesOnly) {
                            Label("Favorites Only", systemImage: "heart")
                        }
                    }
                } label: {
                    Image(systemName: favoritesOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .observing(query)
    }

    @ViewBuilder
    private func tile(_ album: Album) -> some View {
        NavigationLink(value: Route.album(album.id)) {
            AlbumTile(album: album)
        }
        .buttonStyle(.plain)
        .contextMenu {
            AlbumContextMenu(album: album)
        }
    }

    @ViewBuilder
    private func items(_ albums: [Album]) -> some View {
        switch layout {
        case .grid:
            AdaptiveAlbumGrid(items: albums) { album in
                tile(album)
            }
        case .list:
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        AlbumListRow(album: album)
                            .padding(.horizontal, Theme.margin)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { AlbumContextMenu(album: album) }
                    Divider().padding(.leading, Theme.margin + 68)
                }
            }
        }
    }

    private func refine(_ albums: [Album]) -> [Album] {
        let filtered = favoritesOnly ? albums.filter { $0.starred != nil } : albums
        return descending ? filtered.reversed() : filtered
    }

    private var emptyMessage: String {
        if !searchText.isEmpty { return "No results for “\(searchText)”." }
        return favoritesOnly ? "No favorite albums. Turn off the Favorites filter to see everything." : "No albums in your library."
    }

    private func letterSections(from albums: [Album]) -> [LetterSection<Album>] {
        guard hasLetterSections else { return [] }
        return Sectioning.byFirstLetter(albums) { album in
            if sortOrder == .artist {
                return album.artist ?? "Unknown Artist"
            }
            return album.sortName ?? album.name
        }
    }
}
