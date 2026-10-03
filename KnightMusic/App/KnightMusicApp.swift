import SwiftUI

@main
struct KnightMusicApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.player)
                .environment(app.library)
                .environment(app.downloads)
                .environment(app.artwork)
                .environment(app.settings)
                .preferredColorScheme(.dark)
                .task { await app.start() }
        }
    }
}
