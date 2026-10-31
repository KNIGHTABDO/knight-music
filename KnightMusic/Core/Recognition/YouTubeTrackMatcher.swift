import Foundation

/// Finds a recognized song on YouTube Music. Only a result agreeing on both title and artist plays by itself;
/// anything less is offered as a choice, because search happily ranks covers and unrelated songs first.
enum YouTubeTrackMatcher {
    enum Result {
        case match(Song)
        case choices([YTSong])
    }

    static func lookup(title: String, artist: String) async throws -> Result {
        let lead = ShazamService.leadArtist(artist)
        let songs = try await YouTubeMusic.shared.searchSongs("\(title) \(lead)")
        if let best = songs.first(where: { matches($0, title: title, leadArtist: lead) }) {
            return .match(best.song)
        }
        return .choices(Array(songs.prefix(5)))
    }

    private static func matches(_ song: YTSong, title: String, leadArtist: String) -> Bool {
        let wanted = normalized(ShazamService.baseTitle(title))
        guard !wanted.isEmpty, normalized(ShazamService.baseTitle(song.title)) == wanted else { return false }
        let artist = normalized(leadArtist)
        guard !artist.isEmpty else { return false }
        return song.artists.contains { candidate in
            let name = normalized(candidate.name)
            return !name.isEmpty && (name.contains(artist) || artist.contains(name))
        }
    }

    /// "Beyoncé!" and "beyonce" are the same name; non-Latin letters are kept.
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }
}
