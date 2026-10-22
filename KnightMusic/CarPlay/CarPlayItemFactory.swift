import CarPlay
import Foundation
import UIKit

/// Weak reference container for CPListItem instances.
@MainActor
final class CarPlayWeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Evaluates local offline availability for songs, albums, artists and playlists.
@MainActor
final class CarPlayPlayableFilter {
    let appModel: AppModel
    var player: PlayerEngine { appModel.player }

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    var isOffline: Bool { appModel.isOffline }

    func isSongPlayable(_ song: Song) -> Bool {
        if !isOffline && appModel.client != nil { return true }
        if appModel.downloads.localFileURL(for: song.id) != nil { return true }
        if player.streamCache.contains(song.id) { return true }
        return false
    }

    func filterSongs(_ songs: [Song]) -> [Song] {
        if !isOffline && appModel.client != nil { return songs }
        return songs.filter { isSongPlayable($0) }
    }

    func fetchPlayableAlbumIds() async -> Set<String> {
        guard isOffline, let db = appModel.database else { return [] }
        do {
            let ids: [String] = try await db.pool.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT albumId FROM song
                    WHERE albumId IS NOT NULL
                    AND (id IN (SELECT songId FROM download WHERE state = 'done')
                         OR id IN (SELECT songId FROM cachedSong))
                    """
                )
            }
            return Set(ids)
        } catch {
            Log.database.error("fetchPlayableAlbumIds failed: \(error)")
            return []
        }
    }

    func fetchPlayablePlaylistIds() async -> Set<String> {
        guard isOffline, let db = appModel.database else { return [] }
        do {
            let ids: [String] = try await db.pool.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT playlistId FROM playlistEntry
                    WHERE songId IN (SELECT songId FROM download WHERE state = 'done')
                       OR songId IN (SELECT songId FROM cachedSong)
                    """
                )
            }
            return Set(ids)
        } catch {
            Log.database.error("fetchPlayablePlaylistIds failed: \(error)")
            return []
        }
    }

    func fetchPlayableArtistIds() async -> Set<String> {
        guard isOffline, let db = appModel.database else { return [] }
        do {
            let ids: [String] = try await db.pool.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT artistId FROM song
                    WHERE artistId IS NOT NULL
                    AND (id IN (SELECT songId FROM download WHERE state = 'done')
                         OR id IN (SELECT songId FROM cachedSong))
                    """
                )
            }
            return Set(ids)
        } catch {
            Log.database.error("fetchPlayableArtistIds failed: \(error)")
            return []
        }
    }
}

/// Helpers for formatting and building CarPlay list sections and items.
@MainActor
final class CarPlayItemFactory {
    /// Clamps sections to never exceed CarPlay limits (`maximumItemCount` total items, `maximumSectionCount` sections).
    static func clampSections(
        _ sections: [CPListSection],
        maxItems: Int = CPListTemplate.maximumItemCount,
        maxSections: Int = CPListTemplate.maximumSectionCount
    ) -> [CPListSection] {
        guard maxItems > 0, maxSections > 0 else { return [] }
        var result: [CPListSection] = []
        var totalItems = 0

        for section in sections.prefix(maxSections) {
            let remaining = maxItems - totalItems
            if remaining <= 0 { break }
            if section.items.count <= remaining {
                result.append(section)
                totalItems += section.items.count
            } else {
                let clamped = Array(section.items.prefix(remaining))
                result.append(CPListSection(items: clamped, header: section.header, sectionIndexTitle: section.sectionIndexTitle))
                totalItems += clamped.count
                break
            }
        }
        return result
    }

    /// Compares two lists of sections to prevent calling `updateSections` unnecessarily (which resets driver focus).
    static func areSectionsEqual(_ lhs: [CPListSection], _ rhs: [CPListSection]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (s1, s2) in zip(lhs, rhs) {
            if s1.header != s2.header || s1.sectionIndexTitle != s2.sectionIndexTitle {
                return false
            }
            guard s1.items.count == s2.items.count else { return false }
            for (i1, i2) in zip(s1.items, s2.items) {
                if let item1 = i1 as? CPListItem, let item2 = i2 as? CPListItem {
                    let id1 = item1.userInfo as? String
                    let id2 = item2.userInfo as? String
                    if id1 != id2 || item1.text != item2.text || item1.detailText != item2.detailText || item1.accessoryType != item2.accessoryType {
                        return false
                    }
                } else if let row1 = i1 as? CPListImageRowItem, let row2 = i2 as? CPListImageRowItem {
                    let id1 = row1.userInfo as? String
                    let id2 = row2.userInfo as? String
                    if id1 != id2 || row1.text != row2.text {
                        return false
                    }
                } else {
                    return false
                }
            }
        }
        return true
    }

    /// Determines the A–Z letter bucket for a given string. Letters map to "A"..."Z", non-letters to "#".
    static func letterBucket(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        if let char = folded.first, char >= "A" && char <= "Z" {
            return String(char)
        }
        return "#"
    }

    /// Sorts letter buckets alphabetically with "#" at the end.
    static func sortLetters(_ letters: [String]) -> [String] {
        letters.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
    }

    /// Album detail string: `artist · year`.
    static func albumDetailText(artist: String?, year: Int?) -> String? {
        let parts = [artist, year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Song detail string: `artist`.
    static func songDetailText(artist: String?) -> String? {
        guard let artist, !artist.isEmpty else { return nil }
        return artist
    }

    /// Playlist detail string: `N songs`.
    static func playlistDetailText(songCount: Int?) -> String {
        let count = songCount ?? 0
        return count == 1 ? "1 song" : "\(count) songs"
    }
}
