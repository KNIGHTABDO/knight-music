import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.backgroundCompletionHandler = completionHandler
    }
}

@main
struct KnightMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
