import Foundation

/// Track edits for playlists Navidrome syncs from .m3u8 files (the ones Knight writes). Navidrome refuses those
/// edits, so the AutoMix server rewrites the file and waits for Navidrome to re-import it.
enum SyncedPlaylistEditor {
    enum Failure: LocalizedError {
        /// Not a file-synced playlist (or an older server): the original Navidrome error stands.
        case notApplicable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notApplicable: return "This playlist can't be edited."
            case .failed(let message): return message
            }
        }
    }

    struct Result: Decodable {
        var songCount: Int
        /// False when Navidrome hadn't re-imported the file yet; it will on its next scan.
        var imported: Bool
    }

    static func add(_ songIds: [String], to playlistId: String, client: SubsonicClient) async throws -> Result {
        try await edit(playlistId, ["add": songIds], client: client)
    }

    static func remove(indexes: [Int], from playlistId: String, client: SubsonicClient) async throws -> Result {
        try await edit(playlistId, ["removeIndexes": indexes], client: client)
    }

    static func replace(_ playlistId: String, with songIds: [String], client: SubsonicClient) async throws -> Result {
        try await edit(playlistId, ["songIds": songIds], client: client)
    }

    /// Moves the playlist's file to the library's .trash/playlists so Navidrome won't import it again.
    /// `notApplicable` for playlists without a file.
    static func trashFile(of playlistId: String, client: SubsonicClient) async throws {
        _ = try await post("playlists/\(playlistId)/trash", body: [:], client: client)
    }

    private static func edit(_ playlistId: String, _ body: [String: Any], client: SubsonicClient) async throws -> Result {
        let data = try await post("playlists/\(playlistId)/edit", body: body, client: client)
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw Failure.failed("The server's reply couldn't be read.")
        }
    }

    private static func post(_ path: String, body: [String: Any], client: SubsonicClient) async throws -> Data {
        guard let url = client.autoMixURL(path: path) else { throw Failure.notApplicable }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 404, 409: throw Failure.notApplicable
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.failed(message.map { "Couldn't edit the playlist: \($0)" } ?? "Couldn't edit the playlist (HTTP \(status)).")
        }
    }
}
