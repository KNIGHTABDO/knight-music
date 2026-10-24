import Foundation

/// One InnerTube client identity (what YouTube's own apps send). Keys follow yt-dlp's names
/// ("visionos", "ios", "web_music", "android_vr", "tv", ...), so the server's live table maps straight in.
struct YouTubeClientProfile: Codable, Hashable, Sendable {
    var name: String
    var version: String
    var id: Int
    var userAgent: String
    var host: String
    var deviceMake: String?
    var deviceModel: String?
    var osName: String?
    var osVersion: String?
    var androidSdkVersion: Int?

    func context(visitorData: String?) -> [String: Any] {
        var client: [String: Any] = ["clientName": name, "clientVersion": version, "hl": "en", "gl": "US",
                                     "timeZone": "UTC", "utcOffsetMinutes": 0]
        if !userAgent.isEmpty { client["userAgent"] = userAgent }
        if let deviceMake { client["deviceMake"] = deviceMake }
        if let deviceModel { client["deviceModel"] = deviceModel }
        if let osName { client["osName"] = osName }
        if let osVersion { client["osVersion"] = osVersion }
        if let androidSdkVersion { client["androidSdkVersion"] = androidSdkVersion }
        if let visitorData { client["visitorData"] = visitorData }
        return ["client": client]
    }
}

/// Partial client override from the repo's `config/youtube.json` (only the fields it sets).
struct YouTubeClientPatch: Codable, Sendable {
    var name: String?
    var version: String?
    var id: Int?
    var userAgent: String?
    var host: String?
    var deviceMake: String?
    var deviceModel: String?
    var osName: String?
    var osVersion: String?
    var androidSdkVersion: Int?

    func applied(to base: YouTubeClientProfile?) -> YouTubeClientProfile? {
        guard let name = name ?? base?.name, let version = version ?? base?.version, let id = id ?? base?.id else { return nil }
        return YouTubeClientProfile(name: name, version: version, id: id,
                                    userAgent: userAgent ?? base?.userAgent ?? "",
                                    host: host ?? base?.host ?? "www.youtube.com",
                                    deviceMake: deviceMake ?? base?.deviceMake, deviceModel: deviceModel ?? base?.deviceModel,
                                    osName: osName ?? base?.osName, osVersion: osVersion ?? base?.osVersion,
                                    androidSdkVersion: androidSdkVersion ?? base?.androidSdkVersion)
    }
}

/// Everything about talking to YouTube that YouTube can break. Built from bundled defaults, then refreshed
/// from the AutoMix server (yt-dlp's live client table), BitChord's client list and this repo's
/// `config/youtube.json` (kill switch, order, pinned overrides), so fixes land without an app release.
struct YouTubeConfig: Codable, Sendable {
    var clients: [String: YouTubeClientProfile]
    var playerOrder: [String]
    var musicClient: String
    var searchParams: [String: String]
    var disabled: Bool
    var message: String?
    var sources: [String]
    var updated: Date?

    func client(_ key: String) -> YouTubeClientProfile? { clients[key] }

    var music: YouTubeClientProfile { clients[musicClient] ?? Self.bundled.clients["web_music"]! }

    static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    static let bundled = YouTubeConfig(
        clients: [
            "visionos": YouTubeClientProfile(
                name: "VISIONOS", version: "1.02", id: 101,
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                host: "www.youtube.com", deviceMake: "Apple", deviceModel: "RealityDevice17,1",
                osName: "visionOS", osVersion: "26.5.23O471"),
            "ios": YouTubeClientProfile(
                name: "IOS", version: "21.26.4", id: 5,
                userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                host: "youtubei.googleapis.com", deviceMake: "Apple", deviceModel: "iPhone16,2",
                osName: "iPhone", osVersion: "18.3.2.22D82"),
            "android_vr": YouTubeClientProfile(
                name: "ANDROID_VR", version: "1.65.10", id: 28,
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                host: "www.youtube.com", deviceMake: "Oculus", deviceModel: "Quest 3",
                osName: "Android", osVersion: "12L", androidSdkVersion: 32),
            "tv": YouTubeClientProfile(
                name: "TVHTML5", version: "7.20260707.07.00", id: 7,
                userAgent: "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 (KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15",
                host: "www.youtube.com"),
            "web_music": YouTubeClientProfile(
                name: "WEB_REMIX", version: "1.20260707.12.00", id: 67,
                userAgent: webUserAgent, host: "music.youtube.com"),
        ],
        playerOrder: ["visionos", "android_vr", "tv"],
        musicClient: "web_music",
        searchParams: [
            "songs": "EgWKAQIIAWoKEAkQBRAKEAMQBA==",
            "albums": "EgWKAQIYAWoKEAkQAxAEEAkQBQ==",
            "artists": "EgWKAQIgAWoKEAkQChAFEAMQBA==",
            "playlists": "EgeKAQQoAEABagoQAxAEEAoQCRAF",
            "videos": "EgWKAQIQAWoKEAkQChAFEAMQBA==",
        ],
        disabled: false,
        message: nil,
        sources: ["bundled"],
        updated: nil
    )
}

/// `config/youtube.json` in the app's public repo.
struct YouTubeRemoteOverrides: Codable, Sendable {
    var schema: Int?
    var disabled: Bool?
    var message: String?
    var playerOrder: [String]?
    var musicClient: String?
    var searchParams: [String: String]?
    var clients: [String: YouTubeClientPatch]?
}

/// Dotted versions compared numerically ("1.20260707.12.00" vs "1.20260801.01.00", "21.26.4" vs "21.29.1").
func youTubeVersionIsNewer(_ candidate: String, than current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
