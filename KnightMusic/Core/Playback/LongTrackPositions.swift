import Foundation

/// Where you stopped in long tracks (DJ sets, mixes, podcasts), so playing one again picks up there.
/// Local only, newest 200 kept.
@MainActor
final class LongTrackPositions {
    static let minimumDuration: TimeInterval = 15 * 60
    private static let key = "km.longTrackPositions"
    private static let limit = 200

    private struct Entry: Codable {
        var position: TimeInterval
        var savedAt: Date
    }

    private var entries: [String: Entry]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    /// The position to resume `song` at, or nil to start from the top.
    func resumePosition(for song: Song) -> TimeInterval? {
        guard Self.applies(to: song), let entry = entries[song.id] else { return nil }
        return entry.position
    }

    /// Remembers `position`, or forgets the song when it's at the very start or end.
    func record(_ song: Song, at position: TimeInterval) {
        guard Self.applies(to: song) else { return }
        let duration = song.durationSeconds
        if position < 60 || position > duration - 90 {
            guard entries.removeValue(forKey: song.id) != nil else { return }
        } else {
            if let old = entries[song.id], abs(old.position - position) < 5 { return }
            entries[song.id] = Entry(position: position, savedAt: Date())
            if entries.count > Self.limit {
                let oldest = entries.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(entries.count - Self.limit)
                for (id, _) in oldest { entries.removeValue(forKey: id) }
            }
        }
        persist()
    }

    private static func applies(to song: Song) -> Bool {
        !song.isYouTube && song.durationSeconds >= minimumDuration
    }

    private func persist() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: Self.key)
        } catch {
            Log.playback.error("Couldn't save long-track positions: \(error.localizedDescription)")
        }
    }
}
