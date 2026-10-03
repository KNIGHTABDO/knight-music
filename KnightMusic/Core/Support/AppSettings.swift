import SwiftUI

/// User preferences, persisted in UserDefaults. Defaults match the product spec.
@MainActor @Observable
final class AppSettings {
    enum OfflineMode: String, CaseIterable, Codable { case automatic, manual }
    enum ReplayGainMode: String, CaseIterable, Codable { case off, track, album }

    var accentColorHex: String { didSet { save(accentColorHex, "accentColorHex") } }

    /// 0 = no limit. Format "raw" = original file, otherwise a server transcode target such as "mp3" / "opus".
    var wifiMaxBitRate: Int { didSet { save(wifiMaxBitRate, "wifiMaxBitRate") } }
    var wifiFormat: String { didSet { save(wifiFormat, "wifiFormat") } }
    var cellularMaxBitRate: Int { didSet { save(cellularMaxBitRate, "cellularMaxBitRate") } }
    var cellularFormat: String { didSet { save(cellularFormat, "cellularFormat") } }
    var downloadMaxBitRate: Int { didSet { save(downloadMaxBitRate, "downloadMaxBitRate") } }
    var downloadFormat: String { didSet { save(downloadFormat, "downloadFormat") } }

    var offlineMode: OfflineMode { didSet { save(offlineMode.rawValue, "offlineMode") } }
    var manualOfflineEnabled: Bool { didSet { save(manualOfflineEnabled, "manualOfflineEnabled") } }

    var streamCacheLimitMB: Int { didSet { save(streamCacheLimitMB, "streamCacheLimitMB") } }
    var gaplessEnabled: Bool { didSet { save(gaplessEnabled, "gaplessEnabled") } }
    var replayGainMode: ReplayGainMode { didSet { save(replayGainMode.rawValue, "replayGainMode") } }
    var scrobblingEnabled: Bool { didSet { save(scrobblingEnabled, "scrobblingEnabled") } }
    var animatedArtworkEnabled: Bool { didSet { save(animatedArtworkEnabled, "animatedArtworkEnabled") } }
    var lockScreenAnimatedArtworkEnabled: Bool { didSet { save(lockScreenAnimatedArtworkEnabled, "lockScreenAnimatedArtworkEnabled") } }
    var syncPlayQueueWithServer: Bool { didSet { save(syncPlayQueueWithServer, "syncPlayQueueWithServer") } }
    var showRatings: Bool { didSet { save(showRatings, "showRatings") } }

    init() {
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }

        accentColorHex = string("accentColorHex", "#FA2D48")
        wifiMaxBitRate = int("wifiMaxBitRate", 0)
        wifiFormat = string("wifiFormat", "raw")
        cellularMaxBitRate = int("cellularMaxBitRate", 320)
        cellularFormat = string("cellularFormat", "mp3")
        downloadMaxBitRate = int("downloadMaxBitRate", 0)
        downloadFormat = string("downloadFormat", "raw")
        offlineMode = OfflineMode(rawValue: string("offlineMode", "")) ?? .automatic
        manualOfflineEnabled = bool("manualOfflineEnabled", false)
        streamCacheLimitMB = int("streamCacheLimitMB", 2048)
        gaplessEnabled = bool("gaplessEnabled", true)
        replayGainMode = ReplayGainMode(rawValue: string("replayGainMode", "")) ?? .off
        scrobblingEnabled = bool("scrobblingEnabled", true)
        animatedArtworkEnabled = bool("animatedArtworkEnabled", true)
        lockScreenAnimatedArtworkEnabled = bool("lockScreenAnimatedArtworkEnabled", true)
        syncPlayQueueWithServer = bool("syncPlayQueueWithServer", true)
        showRatings = bool("showRatings", true)
    }

    /// Parameters for `SubsonicClient.streamURL` given the current network class.
    func streamParameters(onMeteredNetwork metered: Bool) -> (maxBitRate: Int?, format: String?) {
        let rate = metered ? cellularMaxBitRate : wifiMaxBitRate
        let format = metered ? cellularFormat : wifiFormat
        return (rate > 0 ? rate : nil, format.isEmpty ? nil : format)
    }

    /// Parameters for downloads (original by default).
    var downloadParameters: (maxBitRate: Int?, format: String?) {
        (downloadMaxBitRate > 0 ? downloadMaxBitRate : nil, downloadFormat.isEmpty ? nil : downloadFormat)
    }

    var accentColor: Color {
        let hex = accentColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return Color(red: 0.98, green: 0.176, blue: 0.282) }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
