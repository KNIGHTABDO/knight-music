import Foundation

/// Groups library songs that are the same recording stored more than once (re-imports, a single plus the album copy…).
enum DuplicateSongFinder {
    static let durationTolerance = 3

    static func groups(in songs: [Song]) -> [[Song]] {
        var byKey: [String: [Song]] = [:]
        for song in songs where !song.isYouTube {
            byKey[key(song), default: []].append(song)
        }
        var out: [[Song]] = []
        for candidates in byKey.values where candidates.count > 1 {
            // Same title and artist can still be different recordings (live, remix): split by length.
            var clusters: [[Song]] = []
            for song in candidates.sorted(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }) {
                if let last = clusters.last?.last,
                   abs((last.duration ?? 0) - (song.duration ?? 0)) <= durationTolerance {
                    clusters[clusters.count - 1].append(song)
                } else {
                    clusters.append([song])
                }
            }
            out += clusters.filter { $0.count > 1 }.map { $0.sorted(by: isBetter) }
        }
        return out.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0].title < $1[0].title }
    }

    /// The copy to keep: lossless first, then higher bit rate, then the one on a real album (not a single), then older.
    static func isBetter(_ a: Song, _ b: Song) -> Bool {
        let lossless: Set<String> = ["flac", "alac", "wav", "aiff", "ape", "wv"]
        let la = lossless.contains(a.suffix?.lowercased() ?? ""), lb = lossless.contains(b.suffix?.lowercased() ?? "")
        if la != lb { return la }
        if (a.bitRate ?? 0) != (b.bitRate ?? 0) { return (a.bitRate ?? 0) > (b.bitRate ?? 0) }
        let sa = isSingle(a), sb = isSingle(b)
        if sa != sb { return !sa }
        return (a.created ?? .distantFuture) < (b.created ?? .distantFuture)
    }

    private static func isSingle(_ song: Song) -> Bool {
        let album = song.album?.lowercased() ?? ""
        return album.isEmpty || album.hasSuffix("- single") || album == song.title.lowercased()
    }

    private static func key(_ song: Song) -> String {
        "\(normalize(song.title))|\(normalize(firstArtist(song.artist ?? "")))"
    }

    private static func firstArtist(_ artist: String) -> String {
        let separators = [",", " & ", " feat", " ft.", " x ", ";", " / "]
        var name = artist.lowercased()
        for separator in separators {
            if let range = name.range(of: separator) { name = String(name[..<range.lowerBound]) }
        }
        return name
    }

    private static func normalize(_ text: String) -> String {
        var value = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // "(feat. X)" / "[ft. X]" credits differ between copies of the same file; other brackets (Live, Remix) stay.
        value = value.replacingOccurrences(of: #"[\(\[]\s*(feat|ft|featuring|with)\b[^\)\]]*[\)\]]"#,
                                           with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+(feat|ft|featuring)\.?\s.*$"#, with: "", options: .regularExpression)
        return value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
