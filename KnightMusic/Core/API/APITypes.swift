import Foundation

/// Request-level types shared by SubsonicClient and its callers.

enum SubsonicError: LocalizedError {
    case transport(Error)
    case server(code: Int, message: String)
    case decoding(Error)
    case http(status: Int)
    case invalidURL
    case noReachableServer

    var errorDescription: String? {
        switch self {
        case .transport(let error):
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut { return "The server did not respond in time." }
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNotConnectedToInternet { return "You are not connected to the internet." }
            return "Could not reach the server (\(error.localizedDescription))."
        case .server(let code, let message):
            return code == 40 || code == 41 ? "Wrong username or password." : "Server error \(code): \(message)"
        case .decoding:
            return "The server sent a response Knight Music could not understand."
        case .http(let status):
            return "The server answered with HTTP \(status)."
        case .invalidURL:
            return "The server address is not valid."
        case .noReachableServer:
            return "None of the server addresses could be reached."
        }
    }

    var isTransport: Bool {
        switch self {
        case .transport, .http: return true
        default: return false
        }
    }

    var isAuthFailure: Bool {
        if case .server(let code, _) = self { return code == 40 || code == 41 || code == 44 }
        return false
    }
}

enum AlbumListType: String {
    case newest, recent, frequent, random, alphabeticalByName, alphabeticalByArtist, starred, byYear, byGenre, highest
}

/// Artists / albums / songs bundle returned by search3 and getStarred2.
struct LibraryItems: Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []
}

struct ArtistInfo: Codable, Hashable, Sendable {
    var biography: String?
    var musicBrainzId: String?
    var lastFmUrl: String?
    var smallImageUrl: String?
    var mediumImageUrl: String?
    var largeImageUrl: String?
    var similarArtist: [Artist]?

    /// Biography with Last.fm's trailing HTML link stripped.
    var plainBiography: String? {
        guard let biography, !biography.isEmpty else { return nil }
        var text = biography
        while let open = text.range(of: "<"), let close = text.range(of: ">", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

struct PlayQueueState: Sendable {
    var songs: [Song]
    var currentId: String?
    /// Milliseconds into the current song.
    var positionMs: Int
    var changed: Date?
    var changedBy: String?
}

struct UserInfo: Codable, Hashable, Sendable {
    var username: String
    var scrobblingEnabled: Bool?
    var adminRole: Bool?
    var downloadRole: Bool?
    var playlistRole: Bool?
    var streamRole: Bool?
    var shareRole: Bool?
}

struct OpenSubsonicExtension: Codable, Hashable, Sendable {
    var name: String
    var versions: [Int]?
}

// MARK: - Cleaning
// Navidrome reports "never" as 0001-01-01; treat anything before 1971 as nil.

private func realDate(_ date: Date?) -> Date? {
    guard let date, date.timeIntervalSince1970 > 31_536_000 else { return nil }
    return date
}

extension Song {
    var cleaned: Song {
        var s = self
        s.played = realDate(played)
        s.created = realDate(created)
        s.starred = realDate(starred)
        return s
    }
}

extension Album {
    var cleaned: Album {
        var a = self
        a.played = realDate(played)
        a.created = realDate(created)
        a.starred = realDate(starred)
        return a
    }
}

extension Artist {
    var cleaned: Artist {
        var a = self
        a.starred = realDate(starred)
        return a
    }
}

extension Playlist {
    var cleaned: Playlist {
        var p = self
        p.created = realDate(created)
        p.changed = realDate(changed)
        return p
    }
}
