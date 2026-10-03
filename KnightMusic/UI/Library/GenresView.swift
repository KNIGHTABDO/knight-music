import SwiftUI

struct GenresView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @State private var searchText = ""

    var body: some View {
        let query = library.genres()
        let genres = filtered(query.value)

        Group {
            if !query.isLoaded {
                List {
                    SkeletonRowList(count: 8)
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if genres.isEmpty {
                EmptyStateView(
                    title: "No Genres",
                    systemImage: "guitars",
                    message: searchText.isEmpty ? "No genres found in your library." : "No results for “\(searchText)”."
                )
            } else {
                List(genres) { genre in
                    NavigationLink(value: Route.genre(genre.value)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(genre.value)
                                .font(.kmRowTitle)
                                .foregroundStyle(Theme.label)
                                .lineLimit(1)

                            let songsCount = genre.songCount ?? 0
                            let albumsCount = genre.albumCount ?? 0
                            Text("\(KMFormat.songCount(songsCount)) • \(KMFormat.albumCount(albumsCount))")
                                .font(.kmRowSubtitle)
                                .foregroundStyle(Theme.secondaryLabel)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Genres")
        .searchable(text: $searchText, prompt: "Search in Genres")
        .refreshable { await app.pullToRefresh() }
        .observing(query)
    }

    private func filtered(_ all: [Genre]) -> [Genre] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.value.localizedCaseInsensitiveContains(q) }
    }
}
