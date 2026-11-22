import SwiftUI

enum ArtistSortOrder: String, CaseIterable {
    case name = "Name"
    case albumCount = "Album Count"
}

struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var previousArtists: [Artist] = []
    @State private var sortOrder: ArtistSortOrder = .name
    @AppStorage("artists.favoritesOnly") private var favoritesOnly = false

    var body: some View {
        let query = library.artists(search: debouncedSearch)
        let source = query.isLoaded ? query.value : previousArtists
        let allArtists = sortedArtists(favoritesOnly ? source.filter { $0.starred != nil } : source)
        let sections = Sectioning.byFirstLetter(allArtists, letterFor: \.name)
        let isScrubberVisible = sortOrder == .name && sections.count > 1 && query.isLoaded

        ScrollViewReader { proxy in
            Group {
                if !query.isLoaded && previousArtists.isEmpty {
                    List {
                        SkeletonRowList(count: 8, circularLeading: true)
                            .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else if allArtists.isEmpty {
                    EmptyStateView(
                        title: "No Artists",
                        systemImage: "music.mic",
                        message: !searchText.isEmpty ? "No results for “\(searchText)”."
                            : favoritesOnly ? "No favorite artists yet." : "No artists in your library.",
                        actionTitle: favoritesOnly ? "Show All Artists" : (searchText.isEmpty ? "Sync Now" : nil),
                        action: {
                            if favoritesOnly {
                                favoritesOnly = false
                            } else {
                                Task { await app.pullToRefresh() }
                            }
                        }
                    )
                } else if sortOrder == .name {
                    List {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { artist in
                                    artistRow(artist, clearsScrubber: isScrubberVisible)
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
                        ForEach(allArtists) { artist in
                            artistRow(artist)
                        }
                    }
                }
            }
            .listStyle(.plain)
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
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Search")
        .refreshable { await app.pullToRefresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Sort By") {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(ArtistSortOrder.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
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
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != debouncedSearch {
                if !trimmed.isEmpty || !debouncedSearch.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                if Task.isCancelled { return }
                debouncedSearch = trimmed
            }
        }
        .onChange(of: query.value) { _, new in if query.isLoaded { previousArtists = new } }
    }

    @ViewBuilder
    private func artistRow(_ artist: Artist, clearsScrubber: Bool = false) -> some View {
        ZStack {
            NavigationLink(value: Route.artist(artist.id)) {
                EmptyView()
            }
            .opacity(0)

            ArtistRow(artist: artist)
                .padding(.vertical, 4)
                // Keeps the chevron out from under the trailing A–Z index.
                .padding(.trailing, clearsScrubber ? 24 : 0)
        }
        .listRowBackground(Color.clear)
        .contextMenu {
            ArtistContextMenu(artist: artist)
        }
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
