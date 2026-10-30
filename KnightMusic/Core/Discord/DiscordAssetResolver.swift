import Foundation

/// Resolves, fetches, and registers album artwork with Discord's external-assets API
/// so it can be rendered on Discord Rich Presence activity cards as `mp:external/...`.
actor DiscordAssetResolver {
    static let shared = DiscordAssetResolver()

    private var cache: [String: String] = [:] // key: songId -> "mp:external/..."
    private var inFlight: [String: Task<String?, Never>] = [:]

    func resolveArtwork(
        songId: String,
        artist: String?,
        title: String,
        album: String?,
        directURL: String?,
        token: String,
        applicationId: String
    ) async -> String? {
        if let cached = cache[songId] {
            return cached
        }

        if let existing = inFlight[songId] {
            return await existing.value
        }

        let task = Task<String?, Never> {
            await self.fetchAndRegister(
                artist: artist,
                title: title,
                album: album,
                directURL: directURL,
                token: token,
                applicationId: applicationId
            )
        }

        inFlight[songId] = task
        let result = await task.value
        inFlight.removeValue(forKey: songId)

        if let result {
            cache[songId] = result
        }
        return result
    }

    private func fetchAndRegister(
        artist: String?,
        title: String,
        album: String?,
        directURL: String?,
        token: String,
        applicationId: String
    ) async -> String? {
        // Step 1: Candidate from directURL if it is publicly accessible
        if let directURL, isPublicURL(directURL) {
            if let asset = await registerWithDiscord(imageURL: directURL, token: token, applicationId: applicationId) {
                return asset
            }
        }

        // Step 2: Fallback to iTunes Search API
        if let itunesURL = await searchiTunesArtwork(artist: artist, title: title, album: album) {
            if let asset = await registerWithDiscord(imageURL: itunesURL, token: token, applicationId: applicationId) {
                return asset
            }
        }

        // Step 3: If candidate was not marked public (e.g. dynamic hostname), still attempt Discord registration
        if let directURL, !isPublicURL(directURL) {
            if let asset = await registerWithDiscord(imageURL: directURL, token: token, applicationId: applicationId) {
                return asset
            }
        }

        return nil
    }

    private func isPublicURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return false }

        // Local / private address checks
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return false }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("169.254.") { return false }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), second >= 16 && second <= 31 {
                return false
            }
        }
        return true
    }

    private func registerWithDiscord(imageURL: String, token: String, applicationId: String) async -> String? {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpoint = URL(string: "https://discord.com/api/v10/applications/\(applicationId)/external-assets") else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["urls": [imageURL]]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = list.first,
                  let externalPath = first["external_asset_path"] as? String else {
                return nil
            }

            return "mp:" + externalPath
        } catch {
            return nil
        }
    }

    private func searchiTunesArtwork(artist: String?, title: String, album: String?) async -> String? {
        let queryParts = [artist, album ?? title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !queryParts.isEmpty else { return nil }
        let query = queryParts.joined(separator: " ")

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("KnightMusic/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artwork100 = first["artworkUrl100"] as? String else {
                return nil
            }

            // Upgrade resolution from 100x100 to 600x600
            let artwork600 = artwork100.replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
            return artwork600
        } catch {
            return nil
        }
    }
}
