import Foundation
import os

let kickLog = Logger(subsystem: "com.knightabdo.knightmusic.KickLiveWidget", category: "Kick")

struct KickStreamer: Codable, Hashable, Identifiable {
    var id: String { slug }
    /// Name exactly as written in `kickStreamers`.
    let name: String
    let slug: String
    let category: String?
    let viewers: Int
    let startedAt: Date?

    var url: URL {
        URL(string: "https://kick.com/\(slug)") ?? URL(string: "https://kick.com")!
    }
}

struct KickSnapshot: Codable {
    let live: [KickStreamer]
    let fetchedAt: Date
}

struct KickLiveState {
    /// Last good result, possibly older than the last attempt.
    let snapshot: KickSnapshot?
    /// The most recent fetch failed; `snapshot` is cached data.
    let isOffline: Bool
}

/// One channel from `/public/v1/channels`, parsed leniently: missing fields fall back to defaults.
struct KickChannel {
    let slug: String
    let category: String?
    let isLive: Bool
    let viewers: Int
    let startedAt: Date?

    static func parseList(_ data: Data) throws -> [KickChannel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["data"] as? [Any] else {
            throw KickAPIError.badResponse
        }
        return items.compactMap { ($0 as? [String: Any]).flatMap(KickChannel.init(json:)) }
    }

    init?(json: [String: Any]) {
        guard let slug = json["slug"] as? String, !slug.isEmpty else { return nil }
        let stream = json["stream"] as? [String: Any]
        let category = json["category"] as? [String: Any]
        self.slug = slug
        self.category = (category?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.isLive = (stream?["is_live"] as? NSNumber)?.boolValue ?? false
        self.viewers = max(0, (stream?["viewer_count"] as? NSNumber)?.intValue ?? 0)
        self.startedAt = (stream?["start_time"] as? String).flatMap(Self.parseDate)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
