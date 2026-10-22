import CarPlay
import GRDB

/// CI screenshot mode (scripts/carplay-screens.sh): `-KMDemo YES -KMCarPlayScreen <name>` opens that CarPlay
/// screen once the demo library is synced. Inert in normal launches.
@MainActor
enum CarPlayDebugRouting {
    static var screen: String? {
        guard DebugLaunch.isDemo else { return nil }
        return UserDefaults.standard.string(forKey: "KMCarPlayScreen")
    }

    static func applyIfNeeded(_ coordinator: CarPlayCoordinator) {
        guard let screen else { return }
        Task { @MainActor [weak coordinator] in
            for _ in 0..<120 {
                guard let coordinator else { return }
                if coordinator.appModel.syncStatus.lastSyncAt != nil, coordinator.tabBarTemplate != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let coordinator else { return }
            await route(screen, coordinator: coordinator)
        }
    }

    private static func route(_ screen: String, coordinator: CarPlayCoordinator) async {
        let tabs = coordinator.tabBarTemplate
        switch screen {
        case "listen": tabs?.selectTemplate(at: 0)
        case "library": tabs?.selectTemplate(at: 1)
        case "playlists": tabs?.selectTemplate(at: 2)
        case "downloads": tabs?.selectTemplate(at: 3)
        case "artists":
            tabs?.selectTemplate(at: 1)
            coordinator.libraryTab?.pushArtists()
        case "albums":
            tabs?.selectTemplate(at: 1)
            coordinator.libraryTab?.pushAlbums()
        case "album":
            tabs?.selectTemplate(at: 1)
            if let id = await first({ try LibraryQueries.albums($0, sort: .name, search: "", limit: 1).first?.id }, coordinator) {
                coordinator.push(CarPlayDetailTemplates.makeAlbumDetail(albumId: id, coordinator: coordinator))
            }
        case "artist":
            tabs?.selectTemplate(at: 1)
            if let id = await coordinator.library.artists().load().first?.id {
                coordinator.push(CarPlayDetailTemplates.makeArtistDetail(artistId: id, coordinator: coordinator))
            }
        case "playlist":
            tabs?.selectTemplate(at: 2)
            if let id = await coordinator.library.playlists().load().first?.id {
                coordinator.push(CarPlayDetailTemplates.makePlaylistDetail(playlistId: id, coordinator: coordinator))
            }
        case "nowplaying", "upnext":
            if let album = await coordinator.library.homeList(.newest).load().first {
                coordinator.playAlbum(album)
            }
            guard screen == "upnext" else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let nowPlaying = coordinator.nowPlaying {
                coordinator.push(nowPlaying.makeUpNextTemplate())
            }
        default:
            Log.app.warning("unknown KMCarPlayScreen \(screen)")
        }
    }

    private static func first(_ fetch: @escaping @Sendable (Database) throws -> String?, _ coordinator: CarPlayCoordinator) async -> String? {
        guard let database = coordinator.appModel.database else { return nil }
        return try? await database.pool.read(fetch)
    }
}
