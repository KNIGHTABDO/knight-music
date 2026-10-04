import Foundation

/// A track added by the Hermes agent to the music library.
struct AddedTrack: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(artist):\(title):\(album)" }
    var artist: String
    var title: String
    var album: String
    var folder: String?
    var playlist: String?
}

/// Parses and strips the ```knight-added ... ``` fenced block from assistant output.
enum KnightAddedParser {
    struct ParseResult: Sendable {
        let cleanedText: String
        let addedTracks: [AddedTrack]
    }

    /// Extracts added tracks from the LAST ```knight-added ... ``` block in the text and strips the block.
    static func parse(_ text: String) -> ParseResult {
        let pattern = "```knight-added[\\s\\S]*?```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return ParseResult(cleanedText: text, addedTracks: [])
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let lastMatch = matches.last, let range = Range(lastMatch.range, in: text) else {
            return ParseResult(cleanedText: text, addedTracks: [])
        }

        let fullBlock = String(text[range])

        // Strip leading ```knight-added and trailing ```
        var inner = fullBlock
        if inner.hasPrefix("```knight-added") {
            inner = String(inner.dropFirst("```knight-added".count))
        }
        if inner.hasSuffix("```") {
            inner = String(inner.dropLast(3))
        }
        inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)

        var tracks: [AddedTrack] = []
        if let data = inner.data(using: .utf8) {
            let decoder = JSONDecoder()
            if let list = try? decoder.decode([AddedTrack].self, from: data) {
                tracks = list
            } else if let single = try? decoder.decode(AddedTrack.self, from: data) {
                tracks = [single]
            }
        }

        var cleaned = text
        cleaned.removeSubrange(range)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParseResult(cleanedText: cleaned, addedTracks: tracks)
    }
}
