import Foundation

enum KickLiveStore {
    /// Fetches fresh data and caches it; on failure returns the cached data marked offline.
    static func refresh() async -> KickLiveState {
        do {
            let snapshot = KickSnapshot(live: try await KickAPI().fetchLive(), fetchedAt: Date())
            KickCache.saveSnapshot(snapshot)
            KickCache.setLastFetchFailed(false)
            return KickLiveState(snapshot: snapshot, isOffline: false)
        } catch {
            kickLog.error("Kick fetch failed: \(String(describing: error), privacy: .public)")
            KickCache.setLastFetchFailed(true)
            return KickLiveState(snapshot: KickCache.loadState().snapshot, isOffline: true)
        }
    }
}
