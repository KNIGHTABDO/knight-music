import Foundation

struct QueueSignature: Equatable, Sendable {
    let count: Int
    let orderHash: Int
    let originalOrderHash: Int
    let repeatMode: RepeatMode
    let shuffle: Bool

    static let empty = QueueSignature(
        count: 0,
        orderHash: 0,
        originalOrderHash: 0,
        repeatMode: .off,
        shuffle: false
    )
}

/// Local persistence of the play queue (large, written on change) and playback position (small, written often).
struct SavedQueue: Codable, Sendable {
    var songs: [Song]
    /// Positions (into `songs`) in the original, un-shuffled order. Nil when not shuffled.
    var originalOrder: [Int]?
    var repeatMode: RepeatMode
    var shuffle: Bool
    var revision: UUID? = nil
    var entryIDs: [UUID]? = nil

    func positionIndex(_ saved: SavedPosition) -> Int? {
        if let revision {
            guard saved.queueRevision == revision, let entryID = saved.entryID,
                  let entryIDs, entryIDs.count == songs.count,
                  let index = entryIDs.firstIndex(of: entryID), entryIDs.lastIndex(of: entryID) == index else { return nil }
            return index
        }
        // Older snapshots stored only an index. Preserve their existing paused restore behavior.
        guard saved.queueRevision == nil, songs.indices.contains(saved.currentIndex) else { return nil }
        return saved.currentIndex
    }
}

struct SavedPosition: Codable, Sendable {
    var currentIndex: Int
    var position: TimeInterval
    var savedAt: Date
    var queueRevision: UUID? = nil
    var entryID: UUID? = nil
}

/// One queue + position file pair per account, so switching servers never restores another server's songs.
final class PlayQueueStore: @unchecked Sendable {
    private let base: URL
    private let lock = NSLock()
    private var accountId: String?
    private let ioQueue = DispatchQueue(label: "com.knightabdo.knightmusic.queuestore", qos: .utility)

    init() {
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// Scopes reads/writes to `accountId` (nil: no account, nothing is read or written).
    func setAccount(_ accountId: String?) {
        lock.lock()
        self.accountId = accountId
        lock.unlock()
        guard let accountId else { return }
        ioQueue.sync { adoptLegacyFiles(for: accountId) }
    }

    /// Deletes the active account's saved queue and position.
    func removeAll() {
        guard let urls = currentURLs() else { return }
        ioQueue.sync {
            try? FileManager.default.removeItem(at: urls.queue)
            try? FileManager.default.removeItem(at: urls.position)
        }
    }

    /// Deletes a removed account's saved queue and position (not the active account's: the player owns those).
    func purge(accountId: String) {
        lock.lock()
        let isActive = self.accountId == accountId
        lock.unlock()
        guard !isActive else { return }
        let files = urls(for: accountId)
        ioQueue.async {
            try? FileManager.default.removeItem(at: files.queue)
            try? FileManager.default.removeItem(at: files.position)
        }
    }

    /// Launch sweep: queue files of accounts that no longer exist (removed before this cleanup, or by a crash).
    func sweepOrphanedAccounts(keeping accountIds: Set<String>) {
        let base = self.base
        ioQueue.async {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return }
            for name in names {
                for prefix in ["PlayQueue-", "PlayPosition-"] where name.hasPrefix(prefix) && name.hasSuffix(".json") {
                    let id = String(name.dropFirst(prefix.count).dropLast(".json".count))
                    guard UUID(uuidString: id) != nil, !accountIds.contains(id) else { continue }
                    try? fm.removeItem(at: base.appendingPathComponent(name))
                }
            }
        }
    }

    func save(_ queue: SavedQueue?, synchronous: Bool = false) {
        guard let urls = currentURLs() else { return }
        write(queue, to: urls.queue, synchronous: synchronous)
    }

    func save(_ position: SavedPosition, synchronous: Bool = false) {
        guard let urls = currentURLs() else { return }
        write(position, to: urls.position, synchronous: synchronous)
    }

    func loadQueue() -> SavedQueue? {
        guard let urls = currentURLs() else { return nil }
        return ioQueue.sync { read(SavedQueue.self, from: urls.queue) }
    }

    func loadPosition() -> SavedPosition? {
        guard let urls = currentURLs() else { return nil }
        return ioQueue.sync { read(SavedPosition.self, from: urls.position) }
    }

    private func currentURLs() -> (queue: URL, position: URL)? {
        lock.lock()
        defer { lock.unlock() }
        guard let accountId else { return nil }
        return urls(for: accountId)
    }

    private func urls(for accountId: String) -> (queue: URL, position: URL) {
        (base.appendingPathComponent("PlayQueue-\(accountId).json"),
         base.appendingPathComponent("PlayPosition-\(accountId).json"))
    }

    /// Before per-account files, one unscoped pair existed; the first account configured afterwards inherits it.
    private func adoptLegacyFiles(for accountId: String) {
        let fm = FileManager.default
        let target = urls(for: accountId)
        let legacy = (base.appendingPathComponent("PlayQueue.json"), base.appendingPathComponent("PlayPosition.json"))
        guard fm.fileExists(atPath: legacy.0.path) || fm.fileExists(atPath: legacy.1.path) else { return }
        if !fm.fileExists(atPath: target.queue.path) {
            try? fm.moveItem(at: legacy.0, to: target.queue)
            try? fm.moveItem(at: legacy.1, to: target.position)
        }
        try? fm.removeItem(at: legacy.0)
        try? fm.removeItem(at: legacy.1)
    }

    private func write<T: Encodable & Sendable>(_ value: T?, to url: URL, synchronous: Bool = false) {
        let work: @Sendable () -> Void = {
            let data: Data?
            if let value {
                do {
                    data = try JSONEncoder().encode(value)
                } catch {
                    PlaybackLog.logger.error("Queue encode failed: \(error.localizedDescription)")
                    return
                }
            } else {
                data = nil
            }
            if let data {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    PlaybackLog.logger.error("Queue write failed: \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if synchronous {
            ioQueue.sync(execute: work)
        } else {
            ioQueue.async(execute: work)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            PlaybackLog.logger.error("Queue decode failed: \(error.localizedDescription)")
            return nil
        }
    }
}
