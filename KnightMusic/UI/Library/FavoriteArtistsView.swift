import SwiftUI

struct FavoriteArtistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @State private var searchText = ""
    @State private var sortOrder: ArtistSortOrder = .name

    var body: some View {
        let query = library.favoriteArtists()
        let filtered = filteredArtists(query.value)
        let sorted = sortedArtists(filtered)
        let sections = Sectioning.byFirstLetter(sorted, letterFor: \.name)

        ScrollViewReader { proxy in
            Group {
                if !query.isLoaded {
                    List {
                        SkeletonRowList(count: 8, circularLeading: true)
                            .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else if sorted.isEmpty {
                    EmptyStateView(
                        title: "No Favorite Artists",
                        systemImage: "heart.slash",
                        message: searchText.isEmpty ? "Favorite artists to see them here." : "No results for “\(searchText)”."
                    )
                } else if sortOrder == .name {
                    List {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { artist in
                                    artistRow(artist)
                                }
                            } header: {
                                Text(section.letter)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .id(section.letter)
                            }
                        }
                    }
                } else {
                    List {
                        ForEach(sorted) { artist in
                            artistRow(artist)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                if sortOrder == .name && sections.count > 1 && query.isLoaded {
                    AlphabetIndexScrubber(
                        activeLetters: Set(sections.map(\.letter))
                    ) { letter in
                        Sectioning.scrollToLetter(letter, sections: sections, proxy: proxy)
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .navigationTitle("Favorite Artists")
        .searchable(text: $searchText, prompt: "Search")
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ArtistSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .observing(query)
    }

    @ViewBuilder
    private func artistRow(_ artist: Artist) -> some View {
        ZStack {
            NavigationLink(value: Route.artist(artist.id)) {
                EmptyView()
            }
            .opacity(0)

            ArtistRow(artist: artist)
                .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
        .contextMenu {
            ArtistContextMenu(artist: artist)
        }
    }

    private func filteredArtists(_ artists: [Artist]) -> [Artist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func sortedArtists(_ artists: [Artist]) -> [Artist] {
        switch sortOrder {
        case .name:
            return artists
        case .albumCount:
            return artists.sorted {
                let leftCount = $0.albumCount ?? 0
                let rightCount = $1.albumCount ?? 0
                if leftCount != rightCount {
                    return leftCount > rightCount
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}
