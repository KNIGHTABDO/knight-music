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
                .preferredColorScheme(app.settings.appearance.colorScheme)

                .task { await app.start() }
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "knightmusic" else { return }
                    if url.host == "album" {
                        let albumId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !albumId.isEmpty {
                            NotificationCenter.default.post(name: Notification.Name("KMOpenAlbum"), object: albumId)
                        }
                    } else if let idx = url.pathComponents.firstIndex(of: "album"), idx + 1 < url.pathComponents.count {
                        let albumId = url.pathComponents[idx + 1]
                        NotificationCenter.default.post(name: Notification.Name("KMOpenAlbum"), object: albumId)
                    }
                }
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
