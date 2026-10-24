import Foundation

/// Keeps `YouTubeConfig` current without app releases. Three live sources, all optional:
/// 1. the AutoMix server's `yt/clients` (yt-dlp's own client table; yt-dlp there updates itself daily),
/// 2. BitChord's `PlayerClient.kt` on GitHub (client versions and agents it ships fixes with),
/// 3. this repo's `config/youtube.json` (kill switch, client order, pinned overrides; applied last).
/// For client versions the newest one seen wins. The last good result is kept on disk for offline launches.
actor YouTubeConfigStore {
    static let shared = YouTubeConfigStore()

    static let bitChordURL = URL(string: "https://raw.githubusercontent.com/kushagrasinghx/BitChord/HEAD/shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/innertube/PlayerClient.kt")!
    static let overridesURL = URL(string: "https://raw.githubusercontent.com/KNIGHTABDO/knight-music/main/config/youtube.json")!
    private static let refreshInterval: TimeInterval = 6 * 3600
    private static let forcedRefreshInterval: TimeInterval = 10 * 60

    private struct Stored: Codable {
        var automatic: YouTubeConfig
        var overrides: YouTubeRemoteOverrides?
    }

    private let file: URL
    private var stored: Stored
    private var lastForced: Date = .distantPast
    private var lastAttempt: Date = .distantPast
    private var refreshing: Task<Void, Never>?
    private var serverURL: (@Sendable (String) -> URL?)?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
            stored.automatic = Self.mergingBundled(into: decoded.automatic)
        } else {
            stored = Stored(automatic: .bundled, overrides: nil)
        }
    }

    func setServer(_ url: (@Sendable (String) -> URL?)?) {
        serverURL = url
    }

    var config: YouTubeConfig { Self.apply(stored.overrides, to: stored.automatic) }

    /// Current config right away; a stale one is refreshed in the background (the next call sees the result).
    func current() -> YouTubeConfig {
        if refreshing == nil, Date().timeIntervalSince(lastAttempt) > 120,
           Date().timeIntervalSince(stored.automatic.updated ?? .distantPast) > Self.refreshInterval {
            lastAttempt = Date()
            Task { await self.refresh() }
        }
        return config
    }

    /// An AutoMix server endpoint (with auth) for `path`, or nil when no server is configured.
    func server(_ path: String) -> URL? { serverURL?(path) }

    /// Called when every client failed: something changed on YouTube's side, so look for a fix right away.
    /// Returns true when a refresh actually ran.
    @discardableResult
    func refreshAfterFailure() async -> Bool {
        guard Date().timeIntervalSince(lastForced) > Self.forcedRefreshInterval else { return false }
        lastForced = Date()
        await refresh()
        return true
    }

    func refresh() async {
        if let running = refreshing { return await running.value }
        let task = Task { await self.performRefresh() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func performRefresh() async {
        async let server = fetchServerTable()
        async let bitChord = fetchText(Self.bitChordURL)
        async let overrides = fetchOverrides()
        let (table, kotlin, remote) = await (server, bitChord, overrides)

        var merged = Self.mergingBundled(into: stored.automatic)
        var sources: [String] = ["bundled"]
        if let table {
            Self.applyServerTable(table, to: &merged)
            sources.append("server yt-dlp \(table["ytdlp"] as? String ?? "?")")
        }
        if let kotlin {
            let clients = Self.parseBitChord(kotlin)
            Self.applyBitChord(clients, to: &merged)
            if !clients.isEmpty { sources.append("BitChord") }
        }
        if table != nil || kotlin != nil || remote != nil {
            merged.updated = Date()
        }
        merged.sources = sources
        stored.automatic = merged
        if let remote {
            stored.overrides = remote
            sources.append("repo overrides")
        }
        Log.api.info("YouTube config refreshed from \(sources.joined(separator: ", "))")
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: file, options: .atomic)
        } catch {
            Log.api.warning("Saving YouTube config failed: \(error.localizedDescription)")
        }
    }

    // MARK: Fetching

    private func fetchText(_ url: URL) async -> String? {
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            Log.api.warning("YouTube config source \(url.host ?? "") unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchServerTable() async -> [String: Any]? {
        guard let url = serverURL?("yt/clients") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Log.api.warning("AutoMix server YouTube clients unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchOverrides() async -> YouTubeRemoteOverrides? {
        guard let text = await fetchText(Self.overridesURL), let data = text.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(YouTubeRemoteOverrides.self, from: data)
        } catch {
            Log.api.warning("config/youtube.json is invalid: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Merging

    /// A newer app build can ship newer bundled clients than an old cached config.
    private static func mergingBundled(into config: YouTubeConfig) -> YouTubeConfig {
        var out = config
        for (key, profile) in YouTubeConfig.bundled.clients {
            if let existing = out.clients[key], !youTubeVersionIsNewer(profile.version, than: existing.version) { continue }
            out.clients[key] = profile
        }
        for (key, value) in YouTubeConfig.bundled.searchParams where out.searchParams[key] == nil {
            out.searchParams[key] = value
        }
        return out
    }

    private static func applyServerTable(_ table: [String: Any], to config: inout YouTubeConfig) {
        guard let clients = table["clients"] as? [String: Any] else { return }
        for (key, value) in clients {
            guard let entry = value as? [String: Any], let context = entry["context"] as? [String: Any],
                  let name = context["clientName"] as? String, let version = context["clientVersion"] as? String,
                  let id = (entry["id"] as? Int) ?? config.clients[key]?.id else { continue }
            let existing = config.clients[key]
            if let existing, youTubeVersionIsNewer(existing.version, than: version) { continue }
            let host = (entry["host"] as? String) ?? existing?.host ?? "www.youtube.com"
            config.clients[key] = YouTubeClientProfile(
                name: name, version: version, id: id,
                userAgent: (context["userAgent"] as? String) ?? existing?.userAgent ?? YouTubeConfig.webUserAgent,
                host: host,
                deviceMake: context["deviceMake"] as? String, deviceModel: context["deviceModel"] as? String,
                osName: context["osName"] as? String, osVersion: context["osVersion"] as? String,
                androidSdkVersion: context["androidSdkVersion"] as? Int)
        }
    }

    private static let bitChordKeys = ["IOS": "ios", "ANDROID_VR": "android_vr", "WEB_REMIX": "web_music",
                                       "TVHTML5": "tv", "WEB": "web", "ANDROID": "android", "ANDROID_MUSIC": "android_music"]

    private static func applyBitChord(_ clients: [String: (version: String, userAgent: String?)], to config: inout YouTubeConfig) {
        for (name, client) in clients {
            guard let key = bitChordKeys[name], var existing = config.clients[key],
                  youTubeVersionIsNewer(client.version, than: existing.version) else { continue }
            existing.version = client.version
            if let ua = client.userAgent, !ua.isEmpty { existing.userAgent = ua }
            config.clients[key] = existing
        }
    }

    static func apply(_ overrides: YouTubeRemoteOverrides?, to base: YouTubeConfig) -> YouTubeConfig {
        guard let overrides else { return base }
        var out = base
        if let disabled = overrides.disabled { out.disabled = disabled }
        out.message = overrides.message
        if let order = overrides.playerOrder, !order.isEmpty { out.playerOrder = order }
        if let music = overrides.musicClient { out.musicClient = music }
        for (key, value) in overrides.searchParams ?? [:] { out.searchParams[key] = value }
        for (key, patch) in overrides.clients ?? [:] {
            if let profile = patch.applied(to: out.clients[key]) { out.clients[key] = profile }
        }
        return out
    }

    // MARK: BitChord's PlayerClient.kt

    /// `private val IOS = PlayerClient(clientName = "IOS", clientVersion = "…", userAgent = "…" + "…")` and
    /// `IOS.copy(…)` variants; agents may also name a `const val`. Newest version per client name.
    static func parseBitChord(_ text: String) -> [String: (version: String, userAgent: String?)] {
        let ns = text as NSString
        func groups(_ pattern: String, in range: NSRange? = nil, of source: NSString? = nil) -> [[String?]] {
            let src = source ?? ns
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: src as String, range: range ?? NSRange(location: 0, length: src.length)).map { m in
                (0..<m.numberOfRanges).map { i in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : src.substring(with: r)
                }
            }
        }
        func literals(_ s: String) -> String {
            groups(#""([^"]*)""#, of: s as NSString).compactMap { $0[1] }.joined()
        }
        func first(_ pattern: String, in s: String) -> String? {
            groups(pattern, of: s as NSString).first?[1] ?? nil
        }

        var constants: [String: String] = [:]
        for g in groups(#"const val (\w+)\s*=\s*((?:\s*"[^"]*"\s*\+?)+)"#) {
            if let name = g[1], let value = g[2] { constants[name] = literals(value) }
        }
        var blocks: [String: (name: String?, version: String?, ua: String?)] = [:]
        for g in groups(#"val (\w+)\s*=\s*(?:PlayerClient|(\w+)\.copy)\(([\s\S]*?)\n\s*\)"#) {
            guard let variable = g[1], let body = g[3] else { continue }
            let base = g[2].flatMap { blocks[$0] }
            let name = first(#"clientName\s*=\s*"([^"]+)""#, in: body) ?? base?.name
            let version = first(#"clientVersion\s*=\s*"([^"]+)""#, in: body) ?? base?.version
            var ua = base?.ua
            if let concatenated = first(#"userAgent\s*=\s*((?:\s*"[^"]*"\s*\+?)+)"#, in: body) {
                ua = literals(concatenated)
            } else if let constant = first(#"userAgent\s*=\s*([A-Z_][A-Z0-9_]*)"#, in: body) {
                ua = constants[constant] ?? ua
            }
            blocks[variable] = (name, version, ua)
        }
        var out: [String: (version: String, userAgent: String?)] = [:]
        for block in blocks.values {
            guard let name = block.name, let version = block.version else { continue }
            if let existing = out[name], !youTubeVersionIsNewer(version, than: existing.version) { continue }
            out[name] = (version, block.ua)
        }
        return out
    }
}
