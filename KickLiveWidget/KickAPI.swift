import Foundation

enum KickAPIError: Error {
    case missingCredentials
    case http(Int)
    case badResponse
}

/// Kick official API with an app access token (client credentials).
struct KickAPI {
    private static let batchSize = 50

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// Live streamers from `kickStreamers`, highest viewer count first.
    func fetchLive() async throws -> [KickStreamer] {
        var slugs: [String] = []
        var seen = Set<String>()
        for name in kickStreamers {
            for slug in Self.candidateSlugs(for: name) where seen.insert(slug).inserted {
                slugs.append(slug)
            }
        }

        var channels: [String: KickChannel] = [:]
        for start in stride(from: 0, to: slugs.count, by: Self.batchSize) {
            let batch = Array(slugs[start..<min(start + Self.batchSize, slugs.count)])
            for channel in try await fetchChannels(batch) {
                channels[channel.slug.lowercased()] = channel
            }
        }

        var live: [KickStreamer] = []
        var matched = Set<String>()
        for name in kickStreamers {
            let found = Self.candidateSlugs(for: name).compactMap { channels[$0] }
            guard let channel = found.first(where: \.isLive), matched.insert(channel.slug.lowercased()).inserted else {
                continue
            }
            live.append(KickStreamer(
                name: name,
                slug: channel.slug,
                category: channel.category,
                viewers: channel.viewers,
                startedAt: channel.startedAt
            ))
        }
        return live.sorted { $0.viewers > $1.viewers }
    }

    private static func candidateSlugs(for name: String) -> [String] {
        let lower = name.lowercased()
        let dashed = lower.replacingOccurrences(of: "_", with: "-")
        return dashed == lower ? [lower] : [lower, dashed]
    }

    /// A 400/404 on a batch usually means one bad slug, so the batch is retried one slug at a time.
    private func fetchChannels(_ slugs: [String]) async throws -> [KickChannel] {
        var components = URLComponents(string: "https://api.kick.com/public/v1/channels")
        components?.queryItems = slugs.map { URLQueryItem(name: "slug", value: $0) }
        guard let url = components?.url else { throw KickAPIError.badResponse }

        let (data, status) = try await authorizedGET(url)
        switch status {
        case 200..<300:
            return try KickChannel.parseList(data)
        case 400, 404:
            guard slugs.count > 1 else { return [] }
            return try await withThrowingTaskGroup(of: [KickChannel].self) { group in
                for slug in slugs {
                    group.addTask { try await fetchChannels([slug]) }
                }
                var all: [KickChannel] = []
                for try await part in group { all += part }
                return all
            }
        default:
            throw KickAPIError.http(status)
        }
    }

    private func authorizedGET(_ url: URL) async throws -> (Data, Int) {
        let result = try await get(url, token: try await accessToken(forceRefresh: false))
        guard result.1 == 401 else { return result }
        return try await get(url, token: try await accessToken(forceRefresh: true))
    }

    private func get(_ url: URL, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KickAPIError.badResponse }
        return (data, http.statusCode)
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = KickCache.loadToken(), cached.expiresAt > Date().addingTimeInterval(60) {
            return cached.accessToken
        }
        guard !KickSecrets.CLIENT_ID.isEmpty, !KickSecrets.CLIENT_SECRET.isEmpty else {
            throw KickAPIError.missingCredentials
        }
        guard let url = URL(string: "https://id.kick.com/oauth/token") else { throw KickAPIError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            ("grant_type", "client_credentials"),
            ("client_id", KickSecrets.CLIENT_ID),
            ("client_secret", KickSecrets.CLIENT_SECRET),
        ]).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw KickAPIError.http(status) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw KickAPIError.badResponse
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        KickCache.saveToken(KickCache.Token(accessToken: accessToken, expiresAt: Date().addingTimeInterval(expiresIn)))
        return accessToken
    }

    private static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}
