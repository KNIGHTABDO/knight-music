import CoreSpotlight
import GRDB
import UniformTypeIdentifiers

/// Albums, artists and playlists of the active library in Spotlight. Results open the matching screen through
/// `SpotlightIndexer.route(for:)` (identifiers are "album:<id>", "artist:<id>", "playlist:<id>").
enum SpotlightIndexer {
    private static let batchSize = 500

    /// Rebuilds the account's domain when the library changed since the last pass.
    static func reindex(database: LibraryDatabase) async {
        let domain = "account.\(database.accountId.uuidString)"
        do {
            let entries = try await database.pool.read { db in try self.entries(db) }
            let signature = stableSignature(entries)
            let key = "spotlight.signature.\(domain)"
            guard UserDefaults.standard.string(forKey: key) != signature else { return }
            let items = entries.map { searchableItem($0, domain: domain) }
            let index = CSSearchableIndex.default()
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            for start in stride(from: 0, to: items.count, by: batchSize) {
                try await index.indexSearchableItems(Array(items[start..<min(start + batchSize, items.count)]))
            }
            UserDefaults.standard.set(signature, forKey: key)
            Log.app.info("Spotlight: indexed \(items.count) items")
        } catch {
            Log.app.error("Spotlight indexing failed: \(error.localizedDescription)")
        }
    }

    /// Drops everything indexed for an account (log out / server removed).
    static func removeAll(accountId: UUID) async {
        let domain = "account.\(accountId.uuidString)"
        UserDefaults.standard.removeObject(forKey: "spotlight.signature.\(domain)")
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        } catch {
            Log.app.error("Spotlight cleanup failed: \(error.localizedDescription)")
        }
    }

    static func route(for identifier: String) -> Route? {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "album": return .album(parts[1])
        case "artist": return .artist(parts[1])
        case "playlist": return .playlist(parts[1])
        default: return nil
        }
    }

    private struct Entry: Sendable {
        var kind: String
        var id: String
        var title: String
        var artist: String?
        var detail: String
    }

    private static func entries(_ db: Database) throws -> [Entry] {
        var entries: [Entry] = []
        for row in try Row.fetchAll(db, sql: "SELECT id, name, artist, year, songCount FROM album") {
            let artist: String? = row["artist"]
            let year: Int? = row["year"]
            let songs: Int? = row["songCount"]
            let detail = [artist, year.map(String.init), songs.map { KMFormat.songCount($0) }].compactMap { $0 }.joined(separator: " · ")
            entries.append(Entry(kind: "album", id: row["id"], title: row["name"], artist: artist, detail: detail))
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, name, albumCount FROM artist") {
            let albums: Int? = row["albumCount"]
            let detail = albums.map { $0 == 1 ? "Artist · 1 album" : "Artist · \($0) albums" } ?? "Artist"
            entries.append(Entry(kind: "artist", id: row["id"], title: row["name"], artist: row["name"], detail: detail))
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, name, songCount FROM playlist") {
            let songs: Int? = row["songCount"]
            let detail = ["Playlist", songs.map { KMFormat.songCount($0) }].compactMap { $0 }.joined(separator: " · ")
            entries.append(Entry(kind: "playlist", id: row["id"], title: row["name"], artist: nil, detail: detail))
        }
        return entries
    }

    private static func searchableItem(_ entry: Entry, domain: String) -> CSSearchableItem {
        let type: UTType = entry.kind == "album" ? .audio : entry.kind == "playlist" ? .playlist : .content
        let attributes = CSSearchableItemAttributeSet(contentType: type)
        attributes.title = entry.title
        attributes.artist = entry.artist
        if entry.kind == "album" { attributes.album = entry.title }
        attributes.contentDescription = entry.detail
        let item = CSSearchableItem(uniqueIdentifier: "\(entry.kind):\(entry.id)", domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }

    /// FNV-1a over every entry (Swift's `hashValue` changes between launches).
    private static func stableSignature(_ entries: [Entry]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for entry in entries {
            for byte in "\(entry.kind):\(entry.id):\(entry.title):\(entry.detail)\n".utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        return "\(entries.count)-\(String(hash, radix: 16))"
    }
}
