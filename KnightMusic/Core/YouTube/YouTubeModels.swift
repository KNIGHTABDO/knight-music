import Foundation

struct YTArtistRef: Hashable, Sendable {
    var name: String
    var browseId: String?
}

struct YTSong: Hashable, Sendable, Identifiable {
    var videoId: String
    var title: String
    var artists: [YTArtistRef]
    var album: String?
    var albumId: String?
    var duration: Int?
    var thumbnail: String?
    var isVideo: Bool
    var year: Int?
    var track: Int?

    var id: String { videoId }
    var artistLine: String { artists.map(\.name).joined(separator: ", ") }

    var song: Song {
        Song(id: Song.youTubePrefix + videoId, title: title, album: album,
             albumId: albumId.map { Song.youTubePrefix + $0 },
             artist: artists.isEmpty ? nil : artistLine,
             artistId: artists.first?.browseId.map { Song.youTubePrefix + $0 },
             track: track, year: year, coverArt: thumbnail.map(YouTubeArtwork.normalized),
             contentType: "audio/mp4", suffix: "m4a", duration: duration, bitRate: 128)
    }
}

struct YTAlbumItem: Hashable, Sendable, Identifiable {
    var browseId: String
    var title: String
    var subtitle: String?
    var artists: [YTArtistRef]
    var year: Int?
    var thumbnail: String?
    var id: String { browseId }
}

struct YTArtistItem: Hashable, Sendable, Identifiable {
    var browseId: String
    var name: String
    var subtitle: String?
    var thumbnail: String?
    var id: String { browseId }
}

struct YTPlaylistItem: Hashable, Sendable, Identifiable {
    var browseId: String
    var title: String
    var subtitle: String?
    var thumbnail: String?
    var id: String { browseId }
}

enum YTItem: Hashable, Sendable, Identifiable {
    case song(YTSong)
    case album(YTAlbumItem)
    case artist(YTArtistItem)
    case playlist(YTPlaylistItem)

    var id: String {
        switch self {
        case .song(let s): "s" + s.videoId
        case .album(let a): "a" + a.browseId
        case .artist(let a): "r" + a.browseId
        case .playlist(let p): "p" + p.browseId
        }
    }
}

struct YTBrowseTarget: Hashable, Sendable {
    var browseId: String
    var params: String?
}

struct YTShelf: Hashable, Sendable, Identifiable {
    var title: String
    var items: [YTItem]
    var more: YTBrowseTarget?
    var id: String { title + (items.first?.id ?? "") }
}

struct YTSearchResults: Sendable {
    var songs: [YTSong] = []
    var videos: [YTSong] = []
    var albums: [YTAlbumItem] = []
    var artists: [YTArtistItem] = []
    var playlists: [YTPlaylistItem] = []

    var isEmpty: Bool { songs.isEmpty && videos.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

struct YTAlbumPage: Sendable {
    var browseId: String
    var title: String
    var subtitle: String?
    var artists: [YTArtistRef]
    var year: Int?
    var thumbnail: String?
    var description: String?
    var songs: [YTSong]
    var otherVersions: [YTAlbumItem]
}

struct YTArtistPage: Sendable {
    var browseId: String
    var name: String
    var thumbnail: String?
    var subscribers: String?
    var description: String?
    var topSongs: [YTSong]
    var topSongsMore: YTBrowseTarget?
    var shelves: [YTShelf]
}

struct YTPlaylistPage: Sendable {
    var browseId: String
    var title: String
    var subtitle: String?
    var detail: String?
    var thumbnail: String?
    var songs: [YTSong]
    var continuation: String?
}

/// A grid behind a "More" link (an artist's full discography, all singles, ...).
struct YTBrowseGrid: Sendable {
    var title: String
    var items: [YTItem]
}

extension Song {
    static let youTubePrefix = "yt:"

    var isYouTube: Bool { id.hasPrefix(Song.youTubePrefix) }

    var youTubeVideoId: String? { isYouTube ? String(id.dropFirst(Song.youTubePrefix.count)) : nil }
}

extension String {
    /// "yt:MPREb_…" → "MPREb_…" (nil when the id is not a YouTube one).
    var youTubeBrowseId: String? { hasPrefix(Song.youTubePrefix) ? String(dropFirst(Song.youTubePrefix.count)) : nil }
}

/// YouTube artwork URLs embed their size ("=w60-h60-l90-rj", "=s120", "/hqdefault.jpg"); this rewrites them
/// to the size the screen needs so one stored URL serves every size.
enum YouTubeArtwork {
    static func isRemote(_ coverArt: String) -> Bool { coverArt.hasPrefix("https://") || coverArt.hasPrefix("http://") }

    /// Strips the size so equal artwork gets one cache key.
    static func normalized(_ url: String) -> String {
        if let range = url.range(of: #"=(w\d+-h\d+|s\d+)[^/]*$"#, options: .regularExpression) {
            return String(url[..<range.lowerBound])
        }
        return url
    }

    static func url(_ raw: String, size: Int) -> URL? {
        let base = normalized(raw)
        if base.contains("googleusercontent.com") || base.contains("ggpht.com") {
            return URL(string: "\(base)=w\(size)-h\(size)-l90-rj")
        }
        if let range = base.range(of: "/vi/"), base.contains("ytimg.com") {
            let videoId = base[range.upperBound...].prefix { $0 != "/" }
            return URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
        }
        return URL(string: base)
    }
}
