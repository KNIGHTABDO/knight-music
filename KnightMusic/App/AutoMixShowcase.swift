import Foundation

/// Keeps the "AutoMix Showcase" playlist on the server in step with the AutoMix analysis: every song in it
/// blends beat-matched into the next one. Refreshed at launch, on return to the app and every few minutes.
@MainActor
final class AutoMixShowcase {
    static let playlistName = "AutoMix Showcase"

    private weak var app: AppModel?
    private var loop: Task<Void, Never>?
    private var lastRun = Date.distantPast

    init(app: AppModel) { self.app = app }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refreshIfDue() {
        guard Date().timeIntervalSince(lastRun) > 120 else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard let app, app.settings.autoMixEnabled, app.session == .ready, !app.isOffline else { return }
        lastRun = Date()
        let ids = await app.player.autoMixShowcase()
        guard ids.count >= 3 else { return }
        do {
            try await app.library.upsertPlaylist(named: Self.playlistName, songIds: ids)
            Log.playback.info("AutoMix Showcase: \(ids.count) songs, every transition beat-matched")
        } catch {
            Log.playback.warning("AutoMix Showcase not updated: \(error.localizedDescription)")
        }
    }
}
