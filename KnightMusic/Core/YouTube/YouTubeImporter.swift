import Foundation

/// "Add to Navidrome": the AutoMix server downloads the song with yt-dlp into the music folder, tags it
/// with the YouTube Music metadata and starts a scan, so it becomes a normal library song.
enum YouTubeImporter {
    enum Outcome {
        case downloaded(path: String?)
        case failed(String)
    }

    static func add(_ song: Song, client: SubsonicClient) async -> Outcome {
        guard let videoId = song.youTubeVideoId else { return .failed("Not a YouTube Music song.") }
        guard let url = client.autoMixURL(path: "yt/import") else {
            return .failed("Connect to your Navidrome server first.")
        }
        var meta: [String: Any] = ["videoId": videoId, "title": song.title]
        if let artist = song.artist { meta["artist"] = artist }
        if let album = song.album { meta["album"] = album }
        if let year = song.year { meta["year"] = year }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: meta)
            var job = try await send(request)
            // yt-dlp takes a few seconds to a minute; poll until it settles.
            for _ in 0..<120 where job.state == "queued" || job.state == "downloading" {
                try await Task.sleep(for: .seconds(2))
                guard let statusURL = client.autoMixURL(path: "yt/import/\(videoId)") else { break }
                job = try await send(URLRequest(url: statusURL, timeoutInterval: 20))
            }
            switch job.state {
            case "done": return .downloaded(path: job.path)
            case "failed": return .failed(job.error ?? "The server could not download this song.")
            default: return .failed("The server is still downloading this song.")
            }
        } catch {
            Log.api.warning("Add to Navidrome \(videoId) failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private struct Job: Decodable {
        var state: String
        var error: String?
        var path: String?
    }

    private static func send(_ request: URLRequest) async throws -> Job {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 404 { throw YouTubeError.unavailable("Update the AutoMix server to add YouTube songs.") }
            throw YouTubeError.http(status)
        }
        return try JSONDecoder().decode(Job.self, from: data)
    }
}
