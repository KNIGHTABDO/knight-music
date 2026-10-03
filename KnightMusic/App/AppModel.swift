import SwiftUI

/// Root of the object graph. Owns every long-lived service and wires them together.
@MainActor @Observable
final class AppModel {
    let settings = AppSettings()
    let library = LibraryRepository()
    let downloads = DownloadManager()
    let artwork = AnimatedArtworkService()
    let player: PlayerEngine

    /// Client for the active account/address; nil when logged out.
    private(set) var client: SubsonicClient?

    init() {
        player = PlayerEngine()
    }

    func start() async {
        DebugLaunch.applyIfNeeded(self)
    }
}
