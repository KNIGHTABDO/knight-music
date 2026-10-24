import Foundation

/// Lyrics for YouTube Music songs: time-synced from LRCLIB when it knows the song, else YouTube Music's own
/// (plain) lyrics. Results are kept for the session.
actor YouTubeLyrics {
    static let shared = YouTubeLyrics()

    private var cache: [String: [StructuredLyrics]] = [:]

    func lyrics(for song: Song) async -> [StructuredLyrics] {
        if let cached = cache[song.id] { return cached }
        var result: [StructuredLyrics] = []
        if let lrclib = await lrclib(song) {
            result = [lrclib]
        } else if let videoId = song.youTubeVideoId {
            do {
                if let text = try await YouTubeMusic.shared.lyrics(videoId: videoId) {
                    let lines = text.components(separatedBy: .newlines).map { StructuredLyrics.Line(start: nil, value: $0) }
                    result = [StructuredLyrics(lang: nil, synced: false, displayArtist: song.artist, displayTitle: song.title,
                                               offset: nil, line: lines)]
                }
            } catch {
                Log.api.warning("YouTube lyrics for \(videoId) failed: \(error.localizedDescription)")
            }
        }
        cache[song.id] = result
        return result
    }

    private func lrclib(_ song: Song) async -> StructuredLyrics? {
        guard let artist = song.artist?.components(separatedBy: ", ").first, !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: song.title)]
        if let album = song.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = song.duration { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("KnightMusic (https://github.com/KNIGHTABDO/knight-music)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
                let lines = Self.parseLRC(synced)
                if !lines.isEmpty {
                    return StructuredLyrics(lang: nil, synced: true, displayArtist: song.artist, displayTitle: song.title,
                                            offset: nil, line: lines)
                }
            }
            if let plain = json["plainLyrics"] as? String, !plain.isEmpty {
                return StructuredLyrics(lang: nil, synced: false, displayArtist: song.artist, displayTitle: song.title, offset: nil,
                                        line: plain.components(separatedBy: .newlines).map { .init(start: nil, value: $0) })
            }
        } catch {
            Log.api.warning("LRCLIB lookup failed: \(error.localizedDescription)")
        }
        return nil
    }

    /// "[01:23.45] text" lines → milliseconds.
    static func parseLRC(_ text: String) -> [StructuredLyrics.Line] {
        guard let re = try? NSRegularExpression(pattern: #"^\[(\d+):(\d+(?:\.\d+)?)\]\s?(.*)$"#) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let minutes = Double(ns.substring(with: m.range(at: 1))),
                  let seconds = Double(ns.substring(with: m.range(at: 2))) else { return nil }
            return StructuredLyrics.Line(start: Int((minutes * 60 + seconds) * 1000), value: ns.substring(with: m.range(at: 3)))
        }
    }
}
