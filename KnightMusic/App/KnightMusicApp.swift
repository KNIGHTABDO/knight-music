import SwiftUI

@main
struct KnightMusicApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _app = State(initialValue: model)
        // BGTaskScheduler registration must happen before launch finishes.
        BackgroundSync.register(
            work: { await model.performBackgroundSync() },
            cancel: { Task { @MainActor in model.cancelBackgroundSync() } }
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.player)
                .environment(app.library)
                .environment(app.downloads)
                .environment(app.artwork)
                .environment(app.settings)
                .environment(app.network)
                .environment(app.syncStatus)
                .preferredColorScheme(.dark)
                .task { await app.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: app.handleForeground()
            case .background: app.scheduleBackgroundSync()
            default: break
            }
        }
    }
}
