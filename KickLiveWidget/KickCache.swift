import Foundation

/// Files in the extension's own container (no App Group).
enum KickCache {
    struct Token: Codable {
        let accessToken: String
        let expiresAt: Date
    }

    private struct Status: Codable {
        let lastFetchFailed: Bool
    }

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("KickLive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func loadState() -> KickLiveState {
        KickLiveState(
            snapshot: read(KickSnapshot.self, "snapshot.json"),
            isOffline: read(Status.self, "status.json")?.lastFetchFailed ?? false
        )
    }

    static func saveSnapshot(_ snapshot: KickSnapshot) {
        write(snapshot, "snapshot.json")
    }

    static func setLastFetchFailed(_ failed: Bool) {
        write(Status(lastFetchFailed: failed), "status.json")
    }

    static func loadToken() -> Token? {
        read(Token.self, "token.json")
    }

    static func saveToken(_ token: Token) {
        write(token, "token.json")
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = directory?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            kickLog.error("Unreadable cache \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            kickLog.error("Cache write failed \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
