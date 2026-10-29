import SwiftUI

/// A multi-shelf category drill-down screen (e.g. Chill Hits, Workout Playlists, New Releases albums).
struct YTCategoryView: View {
    let target: YTBrowseTarget
    let title: String

    var body: some View {
        YTLoader(id: target.browseId + (target.params ?? ""), load: { [target] in
            try await YouTubeMusic.shared.category(target)
        }) { feed in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(feed.shelves) { shelf in
                        YTShelfItemDispatcher(shelf: shelf)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .background(Theme.background.ignoresSafeArea())
    }
}
