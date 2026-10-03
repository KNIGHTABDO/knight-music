import Foundation
import GRDB
import SwiftUI

/// Screenshot mode for CI (scripts/screens.sh): `-KMDemo YES -KMScreen <name>`.
/// Logs into demo.navidrome.org, waits for the first sync and exposes the requested screen. Inert in normal launches.
enum DebugLaunch {
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "KMDemo") }
    static var screen: String? { UserDefaults.standard.string(forKey: "KMScreen") }

    static let demoServer = URL(string: "https://demo.navidrome.org")!
    static let demoUser = "demo"
    static let demoPassword = "demo"

    /// Returns true if it handled startup (login + sync), so the caller skips its normal refresh.
    @MainActor @discardableResult
    static func applyIfNeeded(_ app: AppModel) async -> Bool {
        guard isDemo else { return false }
        app.debugScreen = screen
        if app.activeAccount == nil {
            do {
                try await app.login(name: "Navidrome Demo", addresses: [demoServer], username: demoUser, password: demoPassword)
            } catch {
                Log.app.error("demo login failed: \(error)")
                return true
            }
        } else {
            await app.refresh()
        }
        await app.waitForSync()
        return true
    }

    /// Screenshot routing: applies the requested `-KMScreen <name>` once after sync is complete.
    @MainActor
    static func applyRouting(
        screen: String,
        app: AppModel,
        ui: UIState,
        nav: TabNavigationModel,
        isRegular: Bool
    ) async {
        switch screen {
        case "home":
            ui.selectedTab = .home
        case "search":
            ui.selectedTab = .search
        case "artists":
            if isRegular {
                ui.selectedTab = .section(.artists)
            } else {
                ui.selectedTab = .library
                nav.library.append(Route.artists)
            }
        case "albums":
            if isRegular {
                ui.selectedTab = .section(.albums)
            } else {
                ui.selectedTab = .library
                nav.library.append(Route.albums)
            }
        case "songs":
            if isRegular {
                ui.selectedTab = .section(.songs)
            } else {
                ui.selectedTab = .library
                nav.library.append(Route.songs)
            }
        case "playlists":
            if isRegular {
                ui.selectedTab = .section(.playlists)
            } else {
                ui.selectedTab = .library
                nav.library.append(Route.playlists)
            }
        case "album":
            if let database = app.database {
                let firstAlbum = try? await database.pool.read { db in
                    try LibraryQueries.albums(db, sort: .name, search: "", limit: 1).first
                }
                if let firstAlbum {
                    if isRegular {
                        ui.selectedTab = .section(.albums)
                        nav.albums.append(Route.album(firstAlbum.id))
                    } else {
                        ui.selectedTab = .library
                        nav.library.append(Route.album(firstAlbum.id))
                    }
                }
            }
        case "artist":
            if let database = app.database {
                let firstArtist = try? await database.pool.read { db in
                    try LibraryQueries.artists(db, search: "").first
                }
                if let firstArtist {
                    if isRegular {
                        ui.selectedTab = .section(.artists)
                        nav.artists.append(Route.artist(firstArtist.id))
                    } else {
                        ui.selectedTab = .library
                        nav.library.append(Route.artist(firstArtist.id))
                    }
                }
            }
        case "player", "lyrics", "queue":
            if let database = app.database {
                let albumContent = try? await database.pool.read { db -> AlbumContent? in
                    guard let firstAlbum = try LibraryQueries.albums(db, sort: .name, search: "", limit: 1).first else { return nil }
                    return try LibraryQueries.album(db, id: firstAlbum.id)
                }
                if let songs = albumContent?.songs, !songs.isEmpty {
                    app.player.play(songs, startAt: 0, shuffle: false)
                    app.player.pause()
                    switch screen {
                    case "player":
                        ui.playerPanel = .artwork
                    case "lyrics":
                        ui.playerPanel = .lyrics
                    case "queue":
                        ui.playerPanel = .queue
                    default:
                        break
                    }
                    ui.isPlayerPresented = true
                }
            }
        case "settings":
            ui.selectedTab = .settings
        case "server":
            // SettingsView is a stub; if it exposes a server status page push it, else just settings
            ui.selectedTab = .settings
        case "downloads":
            if isRegular {
                ui.selectedTab = .section(.songList(.downloaded))
            } else {
                ui.selectedTab = .library
                nav.library.append(Route.songList(.downloaded))
            }
        case "onboarding":
            // Handled in RootView by presenting LoginView regardless of session
            break
        default:
            break
        }
    }
}

