import Foundation
import CryptoKit

/// Collects query parameters; repeated names (id=1&id=2) are allowed.
struct QueryParams {
    fileprivate(set) var items: [URLQueryItem] = []

    mutating func add(_ name: String, _ value: String?) {
        if let value { items.append(URLQueryItem(name: name, value: value)) }
    }

    mutating func add(_ name: String, _ value: Int?) {
        if let value { items.append(URLQueryItem(name: name, value: String(value))) }
    }

    mutating func add(_ name: String, _ value: Bool?) {
        if let value { items.append(URLQueryItem(name: name, value: value ? "true" : "false")) }
    }

    mutating func add(_ name: String, all values: [String]) {
        for v in values { items.append(URLQueryItem(name: name, value: v)) }
    }
}

/// OpenSubsonic client (Navidrome 0.5x+). Token auth, JSON, typed endpoints.
actor SubsonicClient {
    nonisolated let baseURL: URL
    nonisolated let username: String
    private nonisolated let password: String
    private nonisolated let onTransportError: (@Sendable () -> Void)?
    private let maxAttempts: Int
    private let session: URLSession
    private let decoder: JSONDecoder
    private var extensionNames: Set<String> = []

    static let apiVersion = "1.16.1"
    static let clientName = "KnightMusic"

    init(
        baseURL: URL,
        username: String = "",
        password: String = "",
        requestTimeout: TimeInterval = 15,
        maxAttempts: Int = 2,
        onTransportError: (@Sendable () -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.maxAttempts = max(1, maxAttempts)
        self.onTransportError = onTransportError

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = max(60, requestTimeout * 4)
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            return SubsonicClient.parseDate(raw) ?? Date(timeIntervalSince1970: 0)
        }
        self.decoder = decoder
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - URL builders (nonisolated; embed fresh auth params)

    nonisolated func streamURL(songId: String, maxBitRate: Int? = nil, format: String? = nil, timeOffset: Int? = nil) -> URL {
        var p = QueryParams()
        p.add("id", songId)
        if let maxBitRate, maxBitRate > 0 { p.add("maxBitRate", maxBitRate) }
        if let format, !format.isEmpty { p.add("format", format) }
        if let timeOffset, timeOffset > 0 { p.add("timeOffset", timeOffset) }
        return makeURL("stream", p.items)
    }

    nonisolated func downloadURL(songId: String) -> URL {
        var p = QueryParams()
        p.add("id", songId)
        return makeURL("download", p.items)
    }

    nonisolated func coverArtURL(id: String, size: Int? = nil) -> URL {
        var p = QueryParams()
        p.add("id", id)
        if let size, size > 0 { p.add("size", size) }
        return makeURL("getCoverArt", p.items)
    }

    // MARK: - System

    func ping() async throws {
        let _: Empty = try await perform("ping")
    }

    func getOpenSubsonicExtensions() async throws -> [OpenSubsonicExtension] {
        let r: ExtensionsPayload = try await perform("getOpenSubsonicExtensions")
        let list = r.openSubsonicExtensions ?? []
        extensionNames = Set(list.map(\.name))
        return list
    }

    func getScanStatus() async throws -> ScanStatus {
        let r: ScanPayload = try await perform("getScanStatus")
        return r.scanStatus ?? ScanStatus(scanning: false)
    }

    @discardableResult
    func startScan(fullScan: Bool = false) async throws -> ScanStatus {
        var p = QueryParams()
        if fullScan { p.add("fullScan", true) }
        let r: ScanPayload = try await perform("startScan", p, idempotent: false)
        return r.scanStatus ?? ScanStatus(scanning: true)
    }

    func getUser(username: String) async throws -> UserInfo {
        var p = QueryParams()
        p.add("username", username)
        let r: UserPayload = try await perform("getUser", p)
        guard let user = r.user else { throw SubsonicError.server(code: 70, message: "User not found") }
        return user
    }

    // MARK: - Browsing

    func getArtists() async throws -> [Artist] {
        let r: ArtistsPayload = try await perform("getArtists")
        return (r.artists?.index ?? []).flatMap { $0.artist ?? [] }.map(\.cleaned)
    }

    func getArtist(id: String) async throws -> (Artist, [Album]) {
        var p = QueryParams()
        p.add("id", id)
        let r: ArtistPayload = try await perform("getArtist", p)
        guard let detail = r.artist else { throw SubsonicError.server(code: 70, message: "Artist not found") }
        return (detail.artist.cleaned, detail.albums.map(\.cleaned))
    }

    func getArtistInfo2(id: String, count: Int = 20) async throws -> ArtistInfo {
        var p = QueryParams()
        p.add("id", id)
        p.add("count", count)
        p.add("includeNotPresent", false)
        let r: ArtistInfoPayload = try await perform("getArtistInfo2", p)
        return r.artistInfo2 ?? ArtistInfo()
    }

    /// Navidrome resolves top songs by artist *name*; servers advertising `topSongsByArtistId` also accept an id.
    func getTopSongs(artistName: String, artistId: String? = nil, count: Int = 20) async throws -> [Song] {
        var p = QueryParams()
        p.add("artist", artistName)
        p.add("count", count)
        if let artistId, extensionNames.contains("topSongsByArtistId") { p.add("id", artistId) }
        let r: TopSongsPayload = try await perform("getTopSongs", p)
        return (r.topSongs?.song ?? []).map(\.cleaned)
    }

    func getAlbum(id: String) async throws -> (Album, [Song]) {
        var p = QueryParams()
        p.add("id", id)
        let r: AlbumPayload = try await perform("getAlbum", p)
        guard let detail = r.album else { throw SubsonicError.server(code: 70, message: "Album not found") }
        return (detail.album.cleaned, detail.songs.map(\.cleaned))
    }

    func getAlbumList2(
        type: AlbumListType,
        size: Int = 50,
        offset: Int = 0,
        genre: String? = nil,
        fromYear: Int? = nil,
        toYear: Int? = nil
    ) async throws -> [Album] {
        var p = QueryParams()
        p.add("type", type.rawValue)
        p.add("size", min(size, 500))
        p.add("offset", offset)
        p.add("genre", genre)
        p.add("fromYear", fromYear)
        p.add("toYear", toYear)
        let r: AlbumListPayload = try await perform("getAlbumList2", p)
        return (r.albumList2?.album ?? []).map(\.cleaned)
    }

    func getRandomSongs(size: Int = 50, genre: String? = nil) async throws -> [Song] {
        var p = QueryParams()
        p.add("size", size)
        p.add("genre", genre)
        let r: RandomSongsPayload = try await perform("getRandomSongs", p)
        return (r.randomSongs?.song ?? []).map(\.cleaned)
    }

    func getSongsByGenre(_ genre: String, count: Int = 100, offset: Int = 0) async throws -> [Song] {
        var p = QueryParams()
        p.add("genre", genre)
        p.add("count", count)
        p.add("offset", offset)
        let r: SongsByGenrePayload = try await perform("getSongsByGenre", p)
        return (r.songsByGenre?.song ?? []).map(\.cleaned)
    }

    func getGenres() async throws -> [Genre] {
        let r: GenresPayload = try await perform("getGenres")
        return r.genres?.genre ?? []
    }

    func getStarred2() async throws -> LibraryItems {
        let r: StarredPayload = try await perform("getStarred2")
        return r.starred2?.items ?? LibraryItems()
    }

    /// Navidrome accepts `query: ""` to page through the entire library.
    func search3(
        query: String,
        artistCount: Int = 20, artistOffset: Int = 0,
        albumCount: Int = 20, albumOffset: Int = 0,
        songCount: Int = 20, songOffset: Int = 0
    ) async throws -> LibraryItems {
        var p = QueryParams()
        p.add("query", query)
        p.add("artistCount", artistCount)
        p.add("artistOffset", artistOffset)
        p.add("albumCount", albumCount)
        p.add("albumOffset", albumOffset)
        p.add("songCount", songCount)
        p.add("songOffset", songOffset)
        let r: SearchPayload = try await perform("search3", p)
        return r.searchResult3?.items ?? LibraryItems()
    }

    func getSimilarSongs2(id: String, count: Int = 50) async throws -> [Song] {
        var p = QueryParams()
        p.add("id", id)
        p.add("count", count)
        let r: SimilarSongsPayload = try await perform("getSimilarSongs2", p)
        return (r.similarSongs2?.song ?? []).map(\.cleaned)
    }

    func getInternetRadioStations() async throws -> [RadioStation] {
        let r: RadioPayload = try await perform("getInternetRadioStations")
        return r.internetRadioStations?.internetRadioStation ?? []
    }

    func getLyricsBySongId(id: String) async throws -> [StructuredLyrics] {
        var p = QueryParams()
        p.add("id", id)
        let r: LyricsPayload = try await perform("getLyricsBySongId", p)
        return r.lyricsList?.structuredLyrics ?? []
    }

    // MARK: - Playlists

    func getPlaylists() async throws -> [Playlist] {
        let r: PlaylistsPayload = try await perform("getPlaylists")
        return (r.playlists?.playlist ?? []).map(\.cleaned)
    }

    func getPlaylist(id: String) async throws -> (Playlist, [Song]) {
        var p = QueryParams()
        p.add("id", id)
        let r: PlaylistPayload = try await perform("getPlaylist", p)
        guard let detail = r.playlist else { throw SubsonicError.server(code: 70, message: "Playlist not found") }
        return (detail.playlist.cleaned, detail.songs.map(\.cleaned))
    }

    /// Creates a playlist (`name`) or replaces all entries of an existing one (`playlistId`).
    @discardableResult
    func createPlaylist(name: String? = nil, playlistId: String? = nil, songIds: [String] = []) async throws -> (Playlist, [Song]) {
        var p = QueryParams()
        p.add("name", name)
        p.add("playlistId", playlistId)
        p.add("songId", all: songIds)
        let r: PlaylistPayload = try await perform("createPlaylist", p, idempotent: false)
        guard let detail = r.playlist else { throw SubsonicError.server(code: 0, message: "Playlist was not returned") }
        return (detail.playlist.cleaned, detail.songs.map(\.cleaned))
    }

    func updatePlaylist(
        id: String,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songIdsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) async throws {
        var p = QueryParams()
        p.add("playlistId", id)
        p.add("name", name)
        p.add("comment", comment)
        p.add("public", isPublic)
        p.add("songIdToAdd", all: songIdsToAdd)
        p.add("songIndexToRemove", all: songIndexesToRemove.map(String.init))
        let _: Empty = try await perform("updatePlaylist", p, idempotent: false)
    }

    func deletePlaylist(id: String) async throws {
        var p = QueryParams()
        p.add("id", id)
        let _: Empty = try await perform("deletePlaylist", p, idempotent: false)
    }

    // MARK: - Annotation

    func star(id: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var p = QueryParams()
        p.add("id", id)
        p.add("albumId", albumId)
        p.add("artistId", artistId)
        let _: Empty = try await perform("star", p)
    }

    func unstar(id: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var p = QueryParams()
        p.add("id", id)
        p.add("albumId", albumId)
        p.add("artistId", artistId)
        let _: Empty = try await perform("unstar", p)
    }

    /// Rating 0 clears it. Works for songs, albums and artists.
    func setRating(id: String, rating: Int) async throws {
        var p = QueryParams()
        p.add("id", id)
        p.add("rating", max(0, min(5, rating)))
        let _: Empty = try await perform("setRating", p)
    }

    func scrobble(id: String, time: Date? = nil, submission: Bool = true) async throws {
        var p = QueryParams()
        p.add("id", id)
        if let time { p.add("time", Int(time.timeIntervalSince1970 * 1000)) }
        p.add("submission", submission)
        let _: Empty = try await perform("scrobble", p, idempotent: false)
    }

    // MARK: - Play queue

    func getPlayQueue() async throws -> PlayQueueState? {
        let r: PlayQueuePayload = try await perform("getPlayQueue")
        guard let q = r.playQueue else { return nil }
        return PlayQueueState(
            songs: (q.entry ?? []).map(\.cleaned),
            currentId: q.current,
            positionMs: q.position ?? 0,
            changed: q.changed,
            changedBy: q.changedBy
        )
    }

    func savePlayQueue(ids: [String], current: String?, positionMs: Int) async throws {
        var p = QueryParams()
        p.add("id", all: ids)
        p.add("current", current)
        p.add("position", positionMs)
        let _: Empty = try await perform("savePlayQueue", p, idempotent: false)
    }

    // MARK: - Transport

    private nonisolated func authItems() -> [URLQueryItem] {
        let salt = Self.randomSalt()
        return [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: Self.md5(password + salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    /// AutoMix service on the Navidrome host: same origin under /automix through a proxy (Tailscale, HTTPS),
    /// or port 4534 next to Navidrome's own port on a direct LAN address. Authenticated like Subsonic calls.
    nonisolated func autoMixURL(path: String, items: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        if let port = comps.port, port != 443 { comps.port = 4534 }
        comps.path = "/automix/v1/" + path
        comps.percentEncodedQuery = Self.encodeQuery(authItems() + items)
        return comps.url
    }

    private nonisolated func endpointURL(_ endpoint: String) -> URL {
        baseURL.appendingPathComponent("rest").appendingPathComponent(endpoint)
    }

    private nonisolated func makeURL(_ endpoint: String, _ items: [URLQueryItem]) -> URL {
        let base = endpointURL(endpoint)
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        comps.percentEncodedQuery = Self.encodeQuery(authItems() + items)
        return comps.url ?? base
    }

    private func perform<T: Decodable>(_ endpoint: String, _ params: QueryParams = QueryParams(), idempotent: Bool = true) async throws -> T {
        let query = Self.encodeQuery(authItems() + params.items)
        var request: URLRequest
        let usePost = query.utf8.count > 1800
        if usePost {
            request = URLRequest(url: endpointURL(endpoint))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(query.utf8)
        } else {
            var comps = URLComponents(url: endpointURL(endpoint), resolvingAgainstBaseURL: false)
            comps?.percentEncodedQuery = query
            guard let url = comps?.url else { throw SubsonicError.invalidURL }
            request = URLRequest(url: url)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let attempts = idempotent ? maxAttempts : 1
        var lastError: Error = SubsonicError.invalidURL
        for attempt in 1...attempts {
            do {
                let (data, response) = try await session.data(for: request)
                return try decode(data, response: response, endpoint: endpoint)
            } catch let error as SubsonicError {
                throw error
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = error
                Log.api.warning("\(endpoint) attempt \(attempt)/\(attempts) failed: \(error.localizedDescription)")
                if attempt < attempts { try await Task.sleep(nanoseconds: 400_000_000 * UInt64(attempt)) }
            }
        }
        onTransportError?()
        throw SubsonicError.transport(lastError)
    }

    private func decode<T: Decodable>(_ data: Data, response: URLResponse, endpoint: String) throws -> T {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let envelope: Envelope<T>
        do {
            envelope = try decoder.decode(Envelope<T>.self, from: data)
        } catch {
            if !(200..<300).contains(status) { throw SubsonicError.http(status: status) }
            Log.api.error("\(endpoint) decoding failed: \(error)")
            throw SubsonicError.decoding(error)
        }
        guard envelope.status == "ok", let payload = envelope.payload else {
            let e = envelope.error
            throw SubsonicError.server(code: e?.code ?? 0, message: e?.message ?? "Request failed")
        }
        return payload
    }

    // MARK: - Helpers

    nonisolated static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func randomSalt(length: Int = 12) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement() ?? "a" })
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 3986 encoding; unlike URLComponents this also escapes "+" and "&" inside values.
    nonisolated static func encodeQuery(_ items: [URLQueryItem]) -> String {
        func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        return items.map { "\(esc($0.name))=\(esc($0.value ?? ""))" }.joined(separator: "&")
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO-8601 with or without fractional seconds (Navidrome emits up to nanoseconds, which we clamp to ms).
    nonisolated static func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let start = text.index(after: dot)
            var end = start
            while end < text.endIndex, text[end].isASCII, text[end].isNumber { end = text.index(after: end) }
            let digits = String(text[start..<end])
            let ms = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text.replaceSubrange(start..<end, with: ms)
        }
        return fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }
}

// MARK: - Wire types

private struct Empty: Decodable {}

private struct ServerErrorBody: Decodable {
    let code: Int?
    let message: String?
}

private struct Envelope<T: Decodable>: Decodable {
    let status: String
    let error: ServerErrorBody?
    let payload: T?

    private enum RootKeys: String, CodingKey { case response = "subsonic-response" }
    private enum Keys: String, CodingKey { case status, error }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let inner = try root.superDecoder(forKey: .response)
        let c = try inner.container(keyedBy: Keys.self)
        status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(ServerErrorBody.self, forKey: .error)
        if status == "ok" {
            payload = try T(from: inner)
        } else {
            payload = nil
        }
    }
}

private struct ExtensionsPayload: Decodable { let openSubsonicExtensions: [OpenSubsonicExtension]? }
private struct ScanPayload: Decodable { let scanStatus: ScanStatus? }
private struct UserPayload: Decodable { let user: UserInfo? }

private struct ArtistsPayload: Decodable {
    let artists: Wrapper?
    struct Wrapper: Decodable {
        let index: [Index]?
    }
    struct Index: Decodable {
        let artist: [Artist]?
    }
}

private struct ArtistDetail: Decodable {
    let artist: Artist
    let albums: [Album]
    private enum Keys: String, CodingKey { case album }
    init(from decoder: Decoder) throws {
        artist = try Artist(from: decoder)
        albums = try decoder.container(keyedBy: Keys.self).decodeIfPresent([Album].self, forKey: .album) ?? []
    }
}

private struct AlbumDetail: Decodable {
    let album: Album
    let songs: [Song]
    private enum Keys: String, CodingKey { case song }
    init(from decoder: Decoder) throws {
        album = try Album(from: decoder)
        songs = try decoder.container(keyedBy: Keys.self).decodeIfPresent([Song].self, forKey: .song) ?? []
    }
}

private struct PlaylistDetail: Decodable {
    let playlist: Playlist
    let songs: [Song]
    private enum Keys: String, CodingKey { case entry }
    init(from decoder: Decoder) throws {
        playlist = try Playlist(from: decoder)
        songs = try decoder.container(keyedBy: Keys.self).decodeIfPresent([Song].self, forKey: .entry) ?? []
    }
}

private struct ArtistPayload: Decodable { let artist: ArtistDetail? }
private struct AlbumPayload: Decodable { let album: AlbumDetail? }
private struct PlaylistPayload: Decodable { let playlist: PlaylistDetail? }
private struct ArtistInfoPayload: Decodable { let artistInfo2: ArtistInfo? }

private struct SongList: Decodable { let song: [Song]? }
private struct TopSongsPayload: Decodable { let topSongs: SongList? }
private struct RandomSongsPayload: Decodable { let randomSongs: SongList? }
private struct SongsByGenrePayload: Decodable { let songsByGenre: SongList? }
private struct SimilarSongsPayload: Decodable { let similarSongs2: SongList? }

private struct AlbumListPayload: Decodable {
    let albumList2: Wrapper?
    struct Wrapper: Decodable { let album: [Album]? }
}

private struct GenresPayload: Decodable {
    let genres: Wrapper?
    struct Wrapper: Decodable { let genre: [Genre]? }
}

private struct ItemsBody: Decodable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
    var items: LibraryItems {
        LibraryItems(
            artists: (artist ?? []).map(\.cleaned),
            albums: (album ?? []).map(\.cleaned),
            songs: (song ?? []).map(\.cleaned)
        )
    }
}

private struct StarredPayload: Decodable { let starred2: ItemsBody? }
private struct SearchPayload: Decodable { let searchResult3: ItemsBody? }

private struct RadioPayload: Decodable {
    let internetRadioStations: Wrapper?
    struct Wrapper: Decodable { let internetRadioStation: [RadioStation]? }
}

private struct LyricsPayload: Decodable {
    let lyricsList: Wrapper?
    struct Wrapper: Decodable { let structuredLyrics: [StructuredLyrics]? }
}

private struct PlaylistsPayload: Decodable {
    let playlists: Wrapper?
    struct Wrapper: Decodable { let playlist: [Playlist]? }
}

private struct PlayQueuePayload: Decodable {
    let playQueue: Body?
    struct Body: Decodable {
        let entry: [Song]?
        let current: String?
        let position: Int?
        let changed: Date?
        let changedBy: String?
    }
}
