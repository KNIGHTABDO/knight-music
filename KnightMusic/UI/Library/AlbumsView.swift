import SwiftUI

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @State private var searchText = ""
    @State private var sortOrder: AlbumSort = .name

    private var hasLetterSections: Bool {
        sortOrder == .name || sortOrder == .artist
    }

    var body: some View {
        let query = library.albums(sort: sortOrder, search: searchText)
        let albums = query.value
        let sections = letterSections(from: albums)

        ScrollViewReader { proxy in
            ScrollView {
                if !query.isLoaded {
                    SkeletonTileGrid()
                        .padding(.vertical, Theme.margin)
                } else if albums.isEmpty {
                    EmptyStateView(
                        title: "No Albums",
                        systemImage: "square.stack",
                        message: searchText.isEmpty ? "No albums in your library." : "No results for “\(searchText)”."
                    )
                    .padding(.top, 60)
                } else if hasLetterSections {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 14) {
                                circularBadge(section.letter)
                                    .id(section.letter)
                                    .padding(.horizontal, Theme.margin)

                                AdaptiveAlbumGrid(items: section.items) { album in
                                    tile(album)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Theme.margin)
                } else {
                    AdaptiveAlbumGrid(items: albums) { album in
                        tile(album)
                    }
                    .padding(.vertical, Theme.margin)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .overlay(alignment: .trailing) {
                if hasLetterSections && sections.count > 1 && query.isLoaded {
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
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        Text("Name").tag(AlbumSort.name)
                        Text("Artist").tag(AlbumSort.artist)
                        Text("Year").tag(AlbumSort.year)
                        Text("Recently Added").tag(AlbumSort.recentlyAdded)
                        Text("Most Played").tag(AlbumSort.mostPlayed)
                        Text("Recently Played").tag(AlbumSort.recentlyPlayed)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
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

    private func circularBadge(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.12), in: Circle())
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
