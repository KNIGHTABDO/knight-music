import Foundation
import Observation
import SwiftUI

/// Persists and observes per-song user lyrics timing offsets in milliseconds.
/// Effective offset = server lyrics offset + user offset.
@MainActor @Observable
final class LyricsOffsetStore {
    static let shared = LyricsOffsetStore()

    private static let storageKey = "LyricsUserOffsetsBySongId"

    private let userDefaults: UserDefaults

    /// Map of songId -> offset in milliseconds.
    private(set) var offsets: [String: Int] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let stored = userDefaults.dictionary(forKey: Self.storageKey) {
            var parsed: [String: Int] = [:]
            for (key, val) in stored {
                if let num = val as? Int {
                    parsed[key] = num
                } else if let num = val as? NSNumber {
                    parsed[key] = num.intValue
                }
            }
            self.offsets = parsed
        }
    }

    /// User-defined offset for a song in milliseconds (0 if unchanged).
    func userOffset(for songId: String) -> Int {
        offsets[songId] ?? 0
    }

    /// User-defined offset for a song in milliseconds (alias for userOffset).
    func offset(for songId: String) -> Int {
        userOffset(for: songId)
    }

    /// Sets the user-defined offset for a song in milliseconds and persists to UserDefaults.
    func setOffset(_ offsetMs: Int, for songId: String) {
        if offsetMs == 0 {
            offsets.removeValue(forKey: songId)
        } else {
            offsets[songId] = offsetMs
        }
        userDefaults.set(offsets, forKey: Self.storageKey)
    }

    /// Adjusts the user offset by delta in milliseconds.
    func adjustOffset(by deltaMs: Int, for songId: String) {
        let current = userOffset(for: songId)
        setOffset(current + deltaMs, for: songId)
    }

    /// Resets the user offset back to 0.
    func resetOffset(for songId: String) {
        setOffset(0, for: songId)
    }

    /// Resets the user offset back to 0 (alias).
    func reset(for songId: String) {
        resetOffset(for: songId)
    }

    /// Effective offset combining server lyrics offset and user offset.
    /// Preserves existing server offset sign convention:
    /// currentMs = currentPlaybackMs + effectiveOffset.
    func effectiveOffset(serverOffset: Int?, songId: String) -> Int {
        (serverOffset ?? 0) + userOffset(for: songId)
    }

    /// Effective offset combining server lyrics offset and user offset.
    func effectiveOffset(for lyrics: StructuredLyrics, songId: String) -> Int {
        effectiveOffset(serverOffset: lyrics.offset, songId: songId)
    }

    /// Formats an offset in milliseconds into a concise display string.
    /// E.g. 0 -> "In sync", 1300 -> "+1.3s", -500 -> "−0.5s".
    func formattedOffset(_ offsetMs: Int) -> String {
        if offsetMs == 0 {
            return "In sync"
        }
        let sec = Double(abs(offsetMs)) / 1000.0
        if offsetMs > 0 {
            return String(format: "+%.1fs", sec)
        } else {
            return String(format: "−%.1fs", sec)
        }
    }
}
