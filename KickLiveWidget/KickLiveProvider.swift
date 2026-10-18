import WidgetKit

struct KickLiveEntry: TimelineEntry {
    let date: Date
    let state: KickLiveState
}

struct KickLiveProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 5 * 60
    /// A fetch this recent (e.g. by the refresh button just before reloading) is reused instead of fetching again.
    private static let reuseWindow: TimeInterval = 20

    func placeholder(in context: Context) -> KickLiveEntry {
        KickLiveEntry(date: Date(), state: KickCache.loadState())
    }

    func getSnapshot(in context: Context, completion: @escaping (KickLiveEntry) -> Void) {
        completion(KickLiveEntry(date: Date(), state: KickCache.loadState()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KickLiveEntry>) -> Void) {
        Task {
            let cached = KickCache.loadState()
            let state: KickLiveState
            if !cached.isOffline, let fetchedAt = cached.snapshot?.fetchedAt,
               Date().timeIntervalSince(fetchedAt) < Self.reuseWindow {
                state = cached
            } else {
                state = await KickLiveStore.refresh()
            }

            // One entry per minute keeps the uptime text current until the next fetch.
            let now = Date()
            let entries = stride(from: 0, to: Self.refreshInterval, by: 60).map {
                KickLiveEntry(date: now.addingTimeInterval($0), state: state)
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refreshInterval))))
        }
    }
}
