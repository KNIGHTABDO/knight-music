import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Launches without a phone window (CarPlay, steering-wheel play, Siri) never run RootView's .task.
        AppModel.shared?.startIfNeeded()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

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
        AppModel.shared = model
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
                .environment(app.hermes)
                .environment(app.updates)
                .environment(LookStore.shared)
                .fontDesign(LookStore.shared.current.typeface.design)
                .fontWidth(LookStore.shared.current.typeWidth.width)
                .preferredColorScheme(LookStore.shared.current.appearance.colorScheme)

                .task { app.startIfNeeded() }
        }
        .commands { PlaybackCommands(player: app.player) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: app.handleForeground()
            case .background: app.scheduleBackgroundSync()
            default: break
            }
        }
    }
}
