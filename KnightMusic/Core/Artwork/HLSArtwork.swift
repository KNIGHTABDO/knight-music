import Foundation
import AVFoundation

/// Looks up Apple-Music-style animated artwork on the m8tec mirror and turns its HLS playlists into one local MP4.
/// Each variant playlist references a single fragmented MP4 via byte ranges, so downloading that file whole
/// gives a valid, directly playable asset (no HLS playback needed).
enum HLSArtwork {
    enum SearchOutcome {
        case found(square: URL?, tall: URL?)
        case miss
        case transient
    }

    enum HLSError: Error { case noVariant, noMedia, badStatus(Int), invalidVideo }

    static let targetWidth = 1080

    // MARK: Search

    static func search(artist: String, album: String) async -> SearchOutcome {
        guard var comps = URLComponents(string: "https://artwork.m8tec.top/api/v1/artwork/search") else { return .transient }
        comps.queryItems = [URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "album", value: album)]
        guard let url = comps.url else { return .transient }
        do {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
            guard let http = resp as? HTTPURLResponse else { return .transient }
            if (500...599).contains(http.statusCode) { return .transient }
            guard http.statusCode == 200 else { return .miss }
            struct Reply: Decodable { var url: String?; var url_tall: String? }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return .miss }
            let square = reply.url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let tall = reply.url_tall.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            if square == nil && tall == nil { return .miss }
            return .found(square: square, tall: tall)
        } catch {
            return .transient
        }
    }

    // MARK: Download

    /// Downloads the ~1080px H.264 variant behind a master playlist into `destination` (verified playable video).
    static func downloadMP4(master: URL, to destination: URL) async throws {
        let masterText = try await text(from: master)
        guard let variant = pickVariant(in: masterText, base: master) else { throw HLSError.noVariant }
        let variantText = try await text(from: variant)
        guard let media = mediaFileURL(in: variantText, base: variant) else { throw HLSError.noMedia }

        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: media, timeoutInterval: 90))
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw HLSError.badStatus(http.statusCode) }

        let part = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part.mp4")
        try data.write(to: part, options: .atomic)
        guard await isPlayableVideo(part) else {
            try? FileManager.default.removeItem(at: part)
            throw HLSError.invalidVideo
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
    }

    static func isPlayableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable else { return false }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return false }
        return true
    }

    private static func text(from url: URL) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw HLSError.badStatus(http.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Playlist parsing

    /// avc1 variant whose width is closest to `targetWidth`; ties go to the lowest bandwidth.
    static func pickVariant(in master: String, base: URL) -> URL? {
        let lines = master.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var best: (url: URL, distance: Int, bandwidth: Int)?
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") && line.contains("avc1") {
            guard let width = firstInt(in: line, pattern: "RESOLUTION=(\\d+)x\\d+"),
                  let uriLine = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uriLine, relativeTo: base)?.absoluteURL else { continue }
            let bandwidth = firstInt(in: line, pattern: "[:,]BANDWIDTH=(\\d+)") ?? Int.max
            let distance = abs(width - targetWidth)
            if let b = best, (b.distance, b.bandwidth) <= (distance, bandwidth) { continue }
            best = (url, distance, bandwidth)
        }
        return best?.url
    }

    static func mediaFileURL(in variant: String, base: URL) -> URL? {
        let lines = variant.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let map = lines.first(where: { $0.hasPrefix("#EXT-X-MAP:") }),
           let uri = firstString(in: map, pattern: "URI=\"([^\"]+)\"") {
            return URL(string: uri, relativeTo: base)?.absoluteURL
        }
        if let first = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) {
            return URL(string: first, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private static func firstString(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstInt(in text: String, pattern: String) -> Int? {
        firstString(in: text, pattern: pattern).flatMap(Int.init)
    }

    // MARK: Query cleaning

    /// "Parachutes (Deluxe Edition) [Remastered] - Single" -> "Parachutes"
    static func cleanAlbumName(_ name: String) -> String {
        var s = name
        let noisy = "deluxe|remaster|edition|version|expanded|anniversary|bonus|explicit|clean|special|collector|mono|stereo|feat|ft\\.|with "
        s = s.replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\\((?=[^)]*(?:\(noisy)))[^)]*\\)", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s+[-–—]\\s+(single|ep|deluxe.*|remaster.*|.*edition|.*version)$", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s+(feat\\.|ft\\.|featuring)\\s.*$", with: "", options: [.regularExpression, .caseInsensitive])
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    /// First artist first ("A feat. B", "A; B", "A & B" -> "A"), then the full string as a second attempt.
    static func artistCandidates(_ artist: String) -> [String] {
        let full = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "\\s*(;|,|\\sfeat\\.?\\s|\\sft\\.?\\s|\\sfeaturing\\s|\\s&\\s|\\sx\\s|\\swith\\s).*$"
        let first = full.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        if !first.isEmpty { out.append(first) }
        if !full.isEmpty, full != first { out.append(full) }
        return out
    }
}
