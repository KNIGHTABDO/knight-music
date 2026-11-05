import Foundation

/// Changes to the music files themselves (tags, moving duplicates to the trash). Subsonic has no API for this, so the
/// AutoMix server on the Navidrome host edits the file and waits for Navidrome to re-read it. Admin only.
enum SongFileEditor {
    enum Failure: LocalizedError {
        case unsupported
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "The server can't edit music files. Update the AutoMix service."
            case .failed(let message): return message
            }
        }
    }

    /// Server field names (see server/automix/automix/songs.py). An empty value removes the tag.
    struct TagChanges: Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var year: String?
        var genre: String?
        var track: String?
        var disc: String?

        var isEmpty: Bool { body.isEmpty }

        var body: [String: String] {
            var out: [String: String] = [:]
            out["title"] = title
            out["artist"] = artist
            out["album"] = album
            out["albumArtist"] = albumArtist
            out["year"] = year
            out["genre"] = genre
            out["track"] = track
            out["disc"] = disc
            return out
        }
    }

    /// True once Navidrome has re-read the file; false means it will on its next scan.
    static func retag(_ songId: String, _ changes: TagChanges, client: SubsonicClient) async throws -> Bool {
        let data = try await post("songs/\(songId)/tags", body: changes.body, client: client)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["rescanned"] as? Bool ?? false
    }

    /// Moves the file to the library's .trash/songs folder (move it back to undo).
    static func trash(_ songId: String, client: SubsonicClient) async throws {
        _ = try await post("songs/\(songId)/trash", body: [:], client: client)
    }

    private static func post(_ path: String, body: [String: String], client: SubsonicClient) async throws -> Data {
        guard let url = client.autoMixURL(path: path) else { throw Failure.unsupported }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return data }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        if status == 404, message == nil { throw Failure.unsupported }
        throw Failure.failed(message.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "The server answered HTTP \(status).")
    }
}
