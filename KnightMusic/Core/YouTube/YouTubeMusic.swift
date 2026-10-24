import Foundation

enum YouTubeError: LocalizedError {
    case disabled(String?)
    case unavailable(String)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .disabled(let message): message ?? "YouTube Music is turned off for now."
        case .unavailable(let reason): reason
        case .http(let code): "YouTube Music answered with HTTP \(code)."
        case .invalidResponse: "YouTube Music sent something unexpected."
        }
    }
}

/// A direct audio URL minted by one InnerTube client. Media requests must send the same user agent.
struct YTStream: Sendable {
    var url: URL
    var userAgent: String?
    var contentLength: Int64?
    var client: String
    var expires: Date
    /// YouTube's media servers cap one request; bigger reads are split into ranges of this size.
    var chunkSize: Int64

    func request(range: ClosedRange<Int64>?) -> URLRequest {
        // The server fallback may first download the whole song with yt-dlp.
        var request = URLRequest(url: url, timeoutInterval: client == "server" ? 120 : 30)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return request
    }
}

/// YouTube Music over InnerTube: catalog (WEB_REMIX) and audio streams (player clients from `YouTubeConfig`).
/// A visitor session (cookies + visitorData, like a fresh browser) keeps the player API from asking to sign in.
actor YouTubeMusic {
    static let shared = YouTubeMusic()

    typealias JSON = [String: Any]

    private let session: URLSession
    private var visitorData: String?
    private var visitorFetched: Date = .distantPast
    private var visitorTask: Task<String?, Never>?
    private var streams: [String: YTStream] = [:]
    private var resolving: [String: Task<YTStream, Error>] = [:]
    private var lastGoodClient: String?
    private var store: YouTubeConfigStore { .shared }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    // MARK: Catalog

    func search(_ query: String) async throws -> YTSearchResults {
        let params = await store.current().searchParams
        async let songs = searchItems(query, params: params["songs"])
        async let videos = searchItems(query, params: params["videos"])
        async let albums = searchItems(query, params: params["albums"])
        async let artists = searchItems(query, params: params["artists"])
        async let playlists = searchItems(query, params: params["playlists"])
        let all = await [songs, videos, albums, artists, playlists]
        if all.allSatisfy({ $0 == nil }) {
            // Every filtered search failed: report the first real error.
            _ = try await call("search", ["query": query])
        }
        var results = YTSearchResults()
        results.songs = (all[0] ?? []).compactMap { if case .song(var s) = $0 { s.isVideo = false; return s } else { return nil } }
        results.videos = (all[1] ?? []).compactMap { if case .song(var s) = $0 { s.isVideo = true; return s } else { return nil } }
        results.albums = (all[2] ?? []).compactMap { if case .album(let a) = $0 { return a } else { return nil } }
        results.artists = (all[3] ?? []).compactMap { if case .artist(let a) = $0 { return a } else { return nil } }
        results.playlists = (all[4] ?? []).compactMap { if case .playlist(let p) = $0 { return p } else { return nil } }
        return results
    }

    private func searchItems(_ query: String, params: String?) async -> [YTItem]? {
        var body: JSON = ["query": query]
        if let params { body["params"] = params }
        do {
            return YouTubeParser.search(try await call("search", body))
        } catch {
            Log.api.warning("YouTube search (\(params ?? "all")) failed: \(error.localizedDescription)")
            return nil
        }
    }

    func suggestions(_ query: String) async throws -> [String] {
        YouTubeParser.suggestions(try await call("music/get_search_suggestions", ["input": query]))
    }

    func album(_ browseId: String) async throws -> YTAlbumPage {
        guard let page = YouTubeParser.album(try await browse(browseId), browseId: browseId) else {
            throw YouTubeError.invalidResponse
        }
        return page
    }

    func artist(_ browseId: String) async throws -> YTArtistPage {
        guard var page = YouTubeParser.artist(try await browse(browseId), browseId: browseId) else {
            throw YouTubeError.invalidResponse
        }
        // Artist pages list plays instead of lengths; the "Top songs" playlist behind the header has them.
        if page.topSongs.contains(where: { $0.duration == nil }), let more = page.topSongsMore,
           let full = try? await songs(more) {
            let lengths = Dictionary(full.compactMap { s in s.duration.map { (s.videoId, $0) } }, uniquingKeysWith: { a, _ in a })
            for i in page.topSongs.indices where page.topSongs[i].duration == nil {
                page.topSongs[i].duration = lengths[page.topSongs[i].videoId]
            }
        }
        return page
    }

    func playlist(_ browseId: String) async throws -> YTPlaylistPage {
        let id = browseId.hasPrefix("VL") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("FE") ? browseId : "VL" + browseId
        guard var page = YouTubeParser.playlist(try await browse(id), browseId: browseId) else {
            throw YouTubeError.invalidResponse
        }
        // Long playlists come in pages of 100; read up to 1,000 songs.
        var rounds = 0
        while let token = page.continuation, rounds < 9 {
            rounds += 1
            let next = YouTubeParser.continuationSongs(try await call("browse", ["continuation": token]))
            page.songs += next.songs
            page.continuation = next.songs.isEmpty ? nil : next.continuation
        }
        return page
    }

    func grid(_ target: YTBrowseTarget) async throws -> YTBrowseGrid {
        YouTubeParser.grid(try await browse(target.browseId, params: target.params))
    }

    /// Songs behind a "Top songs ›" link (a playlist).
    func songs(_ target: YTBrowseTarget) async throws -> [YTSong] {
        let root = try await browse(target.browseId, params: target.params)
        return YouTubeParser.items(in: root).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
    }

    /// YouTube Music's endless radio for a song (the seed first).
    func radio(videoId: String) async throws -> [YTSong] {
        let root = try await call("next", ["videoId": videoId, "playlistId": "RDAMVM" + videoId, "isAudioOnly": true,
                                           "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"])
        return YouTubeParser.radio(root)
    }

    /// Plain lyrics from YouTube Music's Lyrics tab (unsynced).
    func lyrics(videoId: String) async throws -> String? {
        let next = try await call("next", ["videoId": videoId, "isAudioOnly": true])
        guard let id = YouTubeParser.lyricsBrowseId(next) else { return nil }
        return YouTubeParser.lyricsText(try await browse(id))
    }

    private func browse(_ browseId: String, params: String? = nil) async throws -> JSON {
        var body: JSON = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await call("browse", body)
    }

    private func call(_ endpoint: String, _ body: JSON) async throws -> JSON {
        let config = await store.current()
        if config.disabled { throw YouTubeError.disabled(config.message) }
        let client = config.music
        let visitor = await visitor()
        var payload = body
        payload["context"] = client.context(visitorData: visitor)
        do {
            return try await post(endpoint, payload, client: client, visitor: visitor)
        } catch YouTubeError.http(let code) where code == 400 || code == 403 {
            // Usually an outdated client version: pick up a fix and try once more.
            guard await store.refreshAfterFailure() else { throw YouTubeError.http(code) }
            let fresh = await store.config.music
            payload["context"] = fresh.context(visitorData: visitor)
            return try await post(endpoint, payload, client: fresh, visitor: visitor)
        }
    }

    private func post(_ endpoint: String, _ payload: JSON, client: YouTubeClientProfile, visitor: String?) async throws -> JSON {
        guard let url = URL(string: "https://\(client.host)/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent.isEmpty ? YouTubeConfig.webUserAgent : client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(client.id), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        let origin = client.host == "music.youtube.com" ? "https://music.youtube.com" : "https://www.youtube.com"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw YouTubeError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSON else { throw YouTubeError.invalidResponse }
        return json
    }

    // MARK: Visitor session

    private func visitor(forceNew: Bool = false) async -> String? {
        if !forceNew, let visitorData, Date().timeIntervalSince(visitorFetched) < 6 * 3600 { return visitorData }
        if let visitorTask { return await visitorTask.value }
        let session = session
        let task = Task<String?, Never> { await Self.fetchVisitor(session: session) }
        visitorTask = task
        let value = await task.value
        visitorTask = nil
        if let value {
            visitorData = value
            visitorFetched = Date()
        }
        return value ?? visitorData
    }

    private static func fetchVisitor(session: URLSession) async -> String? {
        for page in ["https://www.youtube.com/sw.js_data", "https://www.youtube.com/embed/jNQXAC9IVRw"] {
            guard let url = URL(string: page) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(YouTubeConfig.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("PREF=hl=en&tz=UTC; SOCS=CAI", forHTTPHeaderField: "Cookie")
            do {
                let (data, _) = try await session.data(for: request)
                guard let text = String(data: data, encoding: .utf8) else { continue }
                if let match = firstMatch(#""(?:VISITOR_DATA|visitorData)":"([^"]+)""#, in: text) { return match }
                // sw.js_data is ")]}'" + a nested JSON array; the visitor id is its first "Cg…" string.
                if let match = firstMatch(#""(Cg[A-Za-z0-9_%-]{20,}={0,2})""#, in: text) { return match }
            } catch {
                Log.api.warning("YouTube visitor session from \(url.path) failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: Streams

    /// A playable audio stream: player clients in the configured order (the last one that worked first);
    /// when they all fail, a config refresh and one more round; then the AutoMix server's yt-dlp.
    func stream(videoId: String) async throws -> YTStream {
        if let cached = streams[videoId], cached.expires > Date().addingTimeInterval(300) { return cached }
        if let running = resolving[videoId] { return try await running.value }
        let task = Task<YTStream, Error> { try await self.resolveStream(videoId) }
        resolving[videoId] = task
        defer { resolving[videoId] = nil }
        let stream = try await task.value
        streams[videoId] = stream
        return stream
    }

    /// Forget a stream whose URL stopped working (expired or blocked) so the next request mints a new one.
    func invalidate(videoId: String) {
        streams[videoId] = nil
    }

    private func resolveStream(_ videoId: String) async throws -> YTStream {
        let config = await store.current()
        if config.disabled { throw YouTubeError.disabled(config.message) }
        var reasons: [String] = []
        if let stream = await tryClients(videoId, config: config, reasons: &reasons) { return stream }
        if await store.refreshAfterFailure() {
            _ = await visitor(forceNew: true)
            if let stream = await tryClients(videoId, config: await store.config, reasons: &reasons) { return stream }
        }
        if let url = await store.server("yt/audio/\(videoId)") {
            Log.playback.info("YouTube \(videoId): using the AutoMix server (\(reasons.joined(separator: "; ")))")
            return YTStream(url: url, userAgent: nil, contentLength: nil, client: "server",
                            expires: .distantFuture, chunkSize: 8 << 20)
        }
        throw YouTubeError.unavailable(reasons.last ?? "YouTube Music has no playable audio for this song.")
    }

    private func tryClients(_ videoId: String, config: YouTubeConfig, reasons: inout [String]) async -> YTStream? {
        var order = config.playerOrder
        if let lastGoodClient, let index = order.firstIndex(of: lastGoodClient) {
            order.remove(at: index)
            order.insert(lastGoodClient, at: 0)
        }
        for key in order {
            guard let client = config.client(key) else { continue }
            do {
                let stream = try await player(videoId, key: key, client: client)
                lastGoodClient = key
                return stream
            } catch {
                reasons.append("\(key): \(error.localizedDescription)")
            }
        }
        Log.playback.warning("YouTube \(videoId): no client worked (\(reasons.joined(separator: "; ")))")
        return nil
    }

    private func player(_ videoId: String, key: String, client: YouTubeClientProfile) async throws -> YTStream {
        var visitor = await visitor()
        for attempt in 0..<2 {
            var payload: JSON = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
            payload["context"] = client.context(visitorData: visitor)
            let root = try await post("player", payload, client: client, visitor: visitor)
            let status = YouTubeParser.dig(root, "playabilityStatus", "status") as? String ?? "?"
            if status == "OK" {
                return try await pickStream(root, key: key, client: client)
            }
            let reason = YouTubeParser.dig(root, "playabilityStatus", "reason") as? String ?? status
            // A bot check means the visitor session went stale: start a fresh one once.
            if status == "LOGIN_REQUIRED", attempt == 0 {
                visitor = await self.visitor(forceNew: true)
                continue
            }
            throw YouTubeError.unavailable(reason)
        }
        throw YouTubeError.unavailable("sign-in required")
    }

    private func pickStream(_ root: JSON, key: String, client: YouTubeClientProfile) async throws -> YTStream {
        let formats = YouTubeParser.dig(root, "streamingData", "adaptiveFormats") as? [JSON] ?? []
        let audio = formats.filter { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true && $0["url"] != nil }
        let ranked = [140, 139].compactMap { itag in audio.first { $0["itag"] as? Int == itag } } + audio
        guard let format = ranked.first, let string = format["url"] as? String, let url = URL(string: string) else {
            throw YouTubeError.unavailable("no direct AAC audio")
        }
        let length = (format["contentLength"] as? String).flatMap { Int64($0) }
        let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "expire" }?.value.flatMap { TimeInterval($0) }
        let small = key == "android_vr" || key == "tv"
        let stream = YTStream(url: url, userAgent: client.userAgent.isEmpty ? nil : client.userAgent,
                              contentLength: length, client: key,
                              expires: expire.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(5 * 3600),
                              chunkSize: small ? 512 << 10 : 1 << 20)
        // Some clients get URLs that answer 403 (they would need a PO token): check before trusting one.
        let (_, response) = try await session.data(for: stream.request(range: 0...1))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 206 || code == 200 else { throw YouTubeError.http(code) }
        return stream
    }
}
