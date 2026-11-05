import SwiftUI

struct DownloadMostPlayedButton: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui
    @State private var isLoading = false

    var body: some View {
        Button("Download Most Played This Week", systemImage: "arrow.down.circle") {
            Task { await download() }
        }
        .disabled(isLoading)
        .help("Download your 25 most played library songs from the last seven days")
    }

    private func download() async {
        guard let database = app.database else { ui.showToast("Sign in to download songs"); return }
        isLoading = true
        defer { isLoading = false }
        let now = Date()
        let interval = DateInterval(start: now.addingTimeInterval(-7 * 24 * 60 * 60), end: now)
        do {
            // Use Replay's device playEvent history; lifetime server counts cannot describe this week.
            let stats = try await database.pool.read { db in
                try LibraryQueries.replay(db, scope: .allTime, interval: interval)
            }
            let songs = stats.topSongs.map(\.song).filter { !$0.isYouTube }
            guard !songs.isEmpty else { ui.showToast("No library plays in the last seven days"); return }
            downloads.download(songs: songs)
            ui.showToast("Downloading \(songs.count) Most Played Songs")
        } catch {
            Log.database.error("Most played downloads failed: \(error.localizedDescription)")
            ui.showToast(error.localizedDescription)
        }
    }
}
