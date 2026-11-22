import SwiftUI

private struct YouTubeLibraryIndexKey: EnvironmentKey {
    static let defaultValue = YouTubeLibraryIndex.empty
}
private struct YouTubeLibraryMatchesKey: EnvironmentKey {
    static let defaultValue: [String: Song] = [:]
}
extension EnvironmentValues {
    var youTubeLibraryIndex: YouTubeLibraryIndex {
        get { self[YouTubeLibraryIndexKey.self] }
        set { self[YouTubeLibraryIndexKey.self] = newValue }
    }
    var youTubeLibraryMatches: [String: Song] {
        get { self[YouTubeLibraryMatchesKey.self] }
        set { self[YouTubeLibraryMatchesKey.self] = newValue }
    }
}

struct YouTubeLibraryMatching: ViewModifier {
    let songs: [Song]
    @Environment(\.youTubeLibraryIndex) private var index
    @Environment(LibraryRepository.self) private var library
    @State private var matches: [String: Song] = [:]

    private struct Request: Equatable {
        let songs: [Song]
        let revision: Int
    }

    func body(content: Content) -> some View {
        content
            .environment(\.youTubeLibraryMatches, matches)
            .task(id: Request(songs: songs, revision: index.revision)) {
                let snapshot = index
                let sources = songs
                let found = await Task.detached(priority: .userInitiated) { snapshot.matches(sources) }.value
                guard !Task.isCancelled else { return }
                // The index only keeps matching columns; play the full, current rows.
                let rows = await library.songs(ids: Array(Set(found.values.map(\.id))))
                let full = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                guard !Task.isCancelled else { return }
                matches = found.compactMapValues { full[$0.id] }
            }
    }
}

struct InLibraryBadge: View {
    var body: some View {
        Label("In Library", systemImage: "checkmark")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}
