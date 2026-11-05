import SwiftUI
import UIKit
import GRDB

/// Retains requests until a window and the account's restored queue are ready, including cold launches.
@MainActor @Observable
final class AppActionRouter {
    static let shared = AppActionRouter()
    struct Request: Identifiable {
        let id = UUID()
        let action: String
    }
    var requests: [Request] = []

    func submit(_ action: String) { requests.append(Request(action: action)) }

    func handle(_ request: Request, app: AppModel, ui: UIState) async {
        defer { requests.removeAll { $0.id == request.id } }
        do {
            switch request.action {
            case "resume":
                guard !app.player.order.isEmpty else {
                    ui.showToast("No saved queue to resume")
                    return
                }
                app.player.resume()
            case "favorites":
                guard let database = app.database else { return }
                let songs = try await database.pool.read { try LibraryQueries.favoriteSongs($0) }
                guard !songs.isEmpty else { ui.showToast("No favorite songs yet"); return }
                app.player.play(songs, shuffle: true)
            case "recognize":
                if ui.isPlayerPresented {
                    ui.isPlayerPresented = false
                    try await Task.sleep(for: .milliseconds(450))
                }
                // The sheet uses recognitionShouldStart to begin once it is visible.
                ui.startRecognition()
            case "downloads": ui.open(.songList(.downloaded))
            case "love":
                guard let song = app.player.currentSong else { ui.showToast("No song is playing"); return }
                guard !song.isYouTube else { ui.showToast("Add to Navidrome to love this song"); return }
                if song.starred == nil {
                    app.player.toggleStarCurrent()
                    Haptics.impact(.medium)
                }
                ui.showToast("Loved")
            case "import":
                guard let song = app.player.currentSong, song.isYouTube else {
                    ui.showToast("Play a YouTube song first")
                    return
                }
                NavidromeImportCenter.shared.add(song, app: app, ui: ui)
            default: break
            }
        } catch {
            Log.app.error("Quick action failed: \(error.localizedDescription)")
            ui.showToast(error.localizedDescription)
        }
    }

    static func installShortcuts() {
        let items = [("resume", "Resume", "play.fill"),
                     ("favorites", "Shuffle Favorites", "shuffle"),
                     ("recognize", "Recognize Song", "waveform"),
                     ("downloads", "Downloads", "arrow.down.circle")]
        UIApplication.shared.shortcutItems = items.map { action, title, symbol in
            UIApplicationShortcutItem(type: "com.knightmusic." + action, localizedTitle: title,
                                      localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: symbol))
        }
    }
}
