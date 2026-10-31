import Foundation
import GRDB

/// Confirms an import against real rows in the account's mirror, preserving version identity.
enum ImportedSongMatcher {
    static func find(_ source: Song, in database: LibraryDatabase, excluding existingIds: Set<String>,
                     expectedPath: String? = nil) async throws -> Song? {
        try await database.pool.read { db in
            var candidates: [Song] = []
            if let expectedPath {
                let filename = (expectedPath as NSString).lastPathComponent
                candidates = try Song.fetchAll(db, sql: "SELECT * FROM song WHERE path LIKE ? ESCAPE '\\'",
                                               arguments: [LibraryQueries.likePattern(filename)])
            } else {
                let title = baseTitle(source.title)
                candidates = try LibraryQueries.search(db, text: title, limit: 100).songs
                candidates += try Song.fetchAll(db, sql: "SELECT * FROM song ORDER BY created DESC LIMIT 250")
                if let videoId = source.youTubeVideoId {
                    candidates += try Song.fetchAll(db, sql: "SELECT * FROM song WHERE path LIKE ? ESCAPE '\\'",
                                                    arguments: [LibraryQueries.likePattern("[\(videoId)]")])
                }
            }
            var seen = Set<String>()
            return candidates.first { candidate in
                guard !candidate.isYouTube, !existingIds.contains(candidate.id), seen.insert(candidate.id).inserted else { return false }
                if let expectedPath {
                    guard let path = candidate.path else { return false }
                    return path == expectedPath || path.hasSuffix("/" + expectedPath)
                }
                if let videoId = source.youTubeVideoId, candidate.path?.contains("[\(videoId)]") == true { return true }
                guard baseTitle(candidate.title) == baseTitle(source.title),
                      NavidromeImportCenter.versionTags(candidate.title) == NavidromeImportCenter.versionTags(source.title),
                      let artist = source.artist, let other = candidate.artist,
                      ArrivalWatcher.artistOverlaps(trackArtist: artist, songArtist: other) else { return false }
                if let album = source.album, !album.isEmpty,
                   let actualAlbum = candidate.album, !actualAlbum.isEmpty,
                   ArrivalWatcher.normalize(album) != ArrivalWatcher.normalize(actualAlbum) { return false }
                if let duration = source.duration, duration > 0, let actual = candidate.duration, actual > 0 {
                    return abs(duration - actual) <= max(10, duration / 20)
                }
                return true
            }
        }
    }

    private static func baseTitle(_ title: String) -> String {
        var title = title
        if let dash = title.range(of: " - ", options: .backwards),
           !NavidromeImportCenter.versionTags(String(title[dash.upperBound...])).isEmpty {
            title = String(title[..<dash.lowerBound])
        }
        return ArrivalWatcher.normalize(title)
    }
}
