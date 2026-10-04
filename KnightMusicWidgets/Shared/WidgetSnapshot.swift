import Foundation

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let appGroupID = "group.com.knightabdo.knightmusic"
    public static let snapshotFileName = "widget_snapshot.json"
    public static let artworkDirectoryName = "Artwork"

    public typealias NowPlaying = WidgetNowPlaying

    public var nowPlaying: WidgetNowPlaying?
    public var recentAlbums: [WidgetAlbum]
    public var newestAlbums: [WidgetAlbum]
    public var updatedAt: Date

    public init(
        nowPlaying: WidgetNowPlaying? = nil,
        recentAlbums: [WidgetAlbum] = [],
        newestAlbums: [WidgetAlbum] = [],
        updatedAt: Date = Date()
    ) {
        self.nowPlaying = nowPlaying
        self.recentAlbums = recentAlbums
        self.newestAlbums = newestAlbums
        self.updatedAt = updatedAt
    }

    public static let empty = WidgetSnapshot(
        nowPlaying: nil,
        recentAlbums: [],
        newestAlbums: [],
        updatedAt: Date.distantPast
    )

    public func isContentEqual(to other: WidgetSnapshot) -> Bool {
        guard let np1 = nowPlaying, let np2 = other.nowPlaying else {
            return nowPlaying == nil && other.nowPlaying == nil &&
                   recentAlbums == other.recentAlbums &&
                   newestAlbums == other.newestAlbums
        }
        return np1.title == np2.title &&
               np1.artist == np2.artist &&
               np1.album == np2.album &&
               np1.albumId == np2.albumId &&
               np1.isPlaying == np2.isPlaying &&
               abs(np1.duration - np2.duration) < 0.5 &&
               abs(np1.elapsed - np2.elapsed) < 1.0 &&
               np1.artworkFilename == np2.artworkFilename &&
               np1.dominantColorHex == np2.dominantColorHex &&
               recentAlbums == other.recentAlbums &&
               newestAlbums == other.newestAlbums
    }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static var snapshotURL: URL? {
        containerURL?.appendingPathComponent(snapshotFileName)
    }

    public static var artworkDirectoryURL: URL? {
        containerURL?.appendingPathComponent(artworkDirectoryName, isDirectory: true)
    }

    public static func artworkFileURL(for filename: String) -> URL? {
        artworkDirectoryURL?.appendingPathComponent(filename)
    }

    public static func read() -> WidgetSnapshot {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}

public struct WidgetNowPlaying: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumId: String?
    public var isPlaying: Bool
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var timestamp: Date
    public var artworkFilename: String?
    public var dominantColorHex: String?

    public init(
        title: String,
        artist: String,
        album: String,
        albumId: String? = nil,
        isPlaying: Bool = false,
        duration: TimeInterval = 0,
        elapsed: TimeInterval = 0,
        timestamp: Date = Date(),
        artworkFilename: String? = nil,
        dominantColorHex: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumId = albumId
        self.isPlaying = isPlaying
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.artworkFilename = artworkFilename
        self.dominantColorHex = dominantColorHex
    }
}

public struct WidgetAlbum: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var artist: String?
    public var artworkFilename: String?

    public init(
        id: String,
        name: String,
        artist: String? = nil,
        artworkFilename: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artworkFilename = artworkFilename
    }
}
