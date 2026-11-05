import Foundation
import GRDB

/// One background-built index shared by every visible YouTube list. No network or row-level DB reads.
struct YouTubeLibraryIndex: Sendable, Equatable {
    let revision: UUID
    private var titles: [String: [Song]]
    private var videoIDs: [String: Song]

    static let empty = YouTubeLibraryIndex(revision: UUID(), titles: [:], videoIDs: [:])

    init(songs: [Song]) {
        revision = UUID()
        titles = [:]
        videoIDs = [:]
        for song in songs where !song.isYouTube {
            titles[Self.titleKey(song.title), default: []].append(song)
            // Imports retain the source video ID in yt-dlp's [id] filename.
            if let path = song.path,
               let range = path.range(of: #"\[[A-Za-z0-9_-]{11}\]"#, options: .regularExpression) {
                videoIDs[String(path[range].dropFirst().dropLast())] = song
            }
        }
    }

    private init(revision: UUID, titles: [String: [Song]], videoIDs: [String: Song]) {
        self.revision = revision
        self.titles = titles
        self.videoIDs = videoIDs
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision }

    func matches(_ songs: [Song]) -> [String: Song] {
        var result: [String: Song] = [:]
        for source in songs where source.isYouTube {
            if let id = source.youTubeVideoId, let exact = videoIDs[id] {
                result[source.id] = exact
                continue
            }
            let candidates = titles[Self.titleKey(source.title)] ?? []
            result[source.id] = candidates.first { candidate in
                guard NavidromeImportCenter.versionTags(candidate.title) == NavidromeImportCenter.versionTags(source.title),
                      let artist = source.artist, let other = candidate.artist,
                      ArrivalWatcher.artistOverlaps(trackArtist: artist, songArtist: other) else { return false }
                if let album = source.album, !album.isEmpty, let actual = candidate.album, !actual.isEmpty,
                   ArrivalWatcher.normalize(album) != ArrivalWatcher.normalize(actual) { return false }
                if let duration = source.duration, duration > 0, let actual = candidate.duration, actual > 0 {
                    return abs(duration - actual) <= max(10, duration / 20)
                }
                return true
            }
        }
        return result
    }

    private static func titleKey(_ title: String) -> String {
        var base = title
        if let dash = title.range(of: " - ", options: .backwards),
           !NavidromeImportCenter.versionTags(String(title[dash.upperBound...])).isEmpty {
            base = String(title[..<dash.lowerBound])
        }
        return ArrivalWatcher.normalize(base)
    }
}

extension LibraryRepository {
    func youTubeLibraryIndex() -> LiveQuery<YouTubeLibraryIndex> {
        query("youtube-library-index", initial: .empty) { db in
            YouTubeLibraryIndex(songs: try Song.fetchAll(db))
        }
    }
}
