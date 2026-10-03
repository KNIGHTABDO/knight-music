import Foundation
import GRDB

/// Disk cache of streamed songs (Caches/StreamCache/). Songs are fetched in parallel with playback at low
/// priority, using the SAME URL/quality the player streams, then LRU-evicted under the size limit.
final class StreamCache: @unchecked Sendable {
    private struct Entry {
        var relativePath: String
        var bytes: Int
        var lastAccess: Date
        var quality: String?
    }

    private struct Job {
        let songId: String
        let url: URL
        let quality: StreamQuality
        let ext: String
    }

    let directory: URL
    private let session: URLSession
    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var queued: [Job] = []
    private var active: [String: Task<Void, Never>] = [:]
    private var protectedIds: Set<String> = []
    private var limitBytes: Int = 2048 * 1_048_576
    private var database: DatabaseWriter?
    private let maxConcurrent = 3

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("StreamCache", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
    }

    func configure(database: DatabaseWriter) {
        let rows: [CachedSongRecord]
        do {
            rows = try database.read { try CachedSongRecord.fetchAll($0) }
        } catch {
            PlaybackLog.logger.error("StreamCache load failed: \(error.localizedDescription)")
            rows = []
        }
        var missing: [String] = []
        lock.lock()
        self.database = database
        index = [:]
        for row in rows {
            let url = directory.appendingPathComponent(row.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                index[row.songId] = Entry(relativePath: row.relativePath, bytes: row.bytes,
                                          lastAccess: row.lastAccess, quality: row.quality)
            } else {
                missing.append(row.songId)
            }
        }
        let known = Set(index.values.map(\.relativePath))
        lock.unlock()
        if !missing.isEmpty { dropRows(missing) }
        // Orphans (e.g. interrupted moves) only waste space.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in files where !known.contains(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: Lookup

    func cachedFileURL(for songId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = index[songId] else { return nil }
        let url = directory.appendingPathComponent(entry.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index[songId] = nil
            dropRows([songId])
            return nil
        }
        entry.lastAccess = Date()
        index[songId] = entry
        let record = CachedSongRecord(songId: songId, relativePath: entry.relativePath, bytes: entry.bytes,
                                      lastAccess: entry.lastAccess, quality: entry.quality)
        write { try record.save($0) }
        return url
    }

    /// Side-effect free (does not touch LRU order).
    func contains(_ songId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return index[songId] != nil
    }

    func quality(for songId: String) -> StreamQuality {
        lock.lock()
        defer { lock.unlock() }
        return StreamQuality(key: index[songId]?.quality)
    }

    func fileSize(for songId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return index[songId]?.bytes
    }

    var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return index.values.reduce(0) { $0 + $1.bytes }
    }

    // MARK: Fill

    /// Queue a background download of `url` for `songId`. No-op if cached, queued or in flight.
    func cache(songId: String, url: URL, quality: StreamQuality, fileExtension: String, limitMB: Int) {
        lock.lock()
        limitBytes = max(limitMB, 0) * 1_048_576
        let already = index[songId] != nil || active[songId] != nil || queued.contains { $0.songId == songId }
        if !already {
            queued.append(Job(songId: songId, url: url, quality: quality, ext: fileExtension))
        }
        lock.unlock()
        pump()
    }

    /// Keep only these songs in flight/queued, and protect them from eviction.
    func retainOnly(_ songIds: Set<String>) {
        lock.lock()
        protectedIds = songIds
        queued.removeAll { !songIds.contains($0.songId) }
        let cancelled = active.filter { !songIds.contains($0.key) }
        for id in cancelled.keys { active[id] = nil }
        lock.unlock()
        for task in cancelled.values { task.cancel() }
    }

    func remove(songId: String) {
        lock.lock()
        let entry = index.removeValue(forKey: songId)
        lock.unlock()
        if let entry { try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath)) }
        dropRows([songId])
    }

    func clear() {
        lock.lock()
        let tasks = Array(active.values)
        active = [:]
        queued = []
        let paths = index.values.map(\.relativePath)
        index = [:]
        lock.unlock()
        tasks.forEach { $0.cancel() }
        for p in paths { try? FileManager.default.removeItem(at: directory.appendingPathComponent(p)) }
        write { _ = try CachedSongRecord.deleteAll($0) }
    }

    // MARK: Internals

    private func pump() {
        lock.lock()
        while active.count < maxConcurrent, !queued.isEmpty {
            let job = queued.removeFirst()
            let task = Task.detached(priority: .utility) { [weak self] in
                await self?.run(job)
                return
            }
            active[job.songId] = task
        }
        lock.unlock()
    }

    private func run(_ job: Job) async {
        var request = URLRequest(url: job.url)
        request.networkServiceType = .background
        do {
            let (tmp, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let mime = http.mimeType?.lowercased() ?? ""
            // Subsonic reports errors as HTTP 200 with a JSON/XML body.
            if mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text") {
                throw URLError(.cannotParseResponse)
            }
            try Task.checkCancellation()
            store(tmp: tmp, job: job)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            PlaybackLog.logger.error("Stream cache download failed for \(job.songId): \(error.localizedDescription)")
        }
        lock.lock()
        active[job.songId] = nil
        lock.unlock()
        pump()
    }

    private func store(tmp: URL, job: Job) {
        let name = "\(safeFileComponent(job.songId)).\(job.ext)"
        let dest = directory.appendingPathComponent(name)
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            excludeFromBackup(dest)
            let size = (try fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                try? fm.removeItem(at: dest)
                return
            }
            let entry = Entry(relativePath: name, bytes: size, lastAccess: Date(), quality: job.quality.key)
            lock.lock()
            index[job.songId] = entry
            lock.unlock()
            let record = CachedSongRecord(songId: job.songId, relativePath: name, bytes: size,
                                          lastAccess: entry.lastAccess, quality: entry.quality)
            write { try record.save($0) }
            evictIfNeeded()
        } catch {
            PlaybackLog.logger.error("Stream cache store failed for \(job.songId): \(error.localizedDescription)")
        }
    }

    private func evictIfNeeded() {
        lock.lock()
        var total = index.values.reduce(0) { $0 + $1.bytes }
        var victims: [(String, Entry)] = []
        if total > limitBytes {
            let candidates = index.filter { !protectedIds.contains($0.key) }
                .sorted { $0.value.lastAccess < $1.value.lastAccess }
            for (id, entry) in candidates where total > limitBytes {
                victims.append((id, entry))
                total -= entry.bytes
            }
            for (id, _) in victims { index[id] = nil }
        }
        lock.unlock()
        guard !victims.isEmpty else { return }
        for (_, entry) in victims {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath))
        }
        dropRows(victims.map(\.0))
    }

    private func dropRows(_ ids: [String]) {
        write { _ = try CachedSongRecord.deleteAll($0, keys: ids) }
    }

    private func write(_ work: @escaping @Sendable (Database) throws -> Void) {
        guard let db = database else { return }
        Task.detached(priority: .utility) {
            do {
                try await db.write(work)
            } catch {
                PlaybackLog.logger.error("StreamCache db write failed: \(error.localizedDescription)")
            }
        }
    }
}
