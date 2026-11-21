import Foundation
import GRDB

/// A song being saved for playback, for the transfers indicator.
struct CacheTransfer: Equatable, Sendable, Identifiable {
    var songId: String
    /// 0…1, nil while queued or before the size is known.
    var fraction: Double?
    /// Needed by AutoMix for the next transition.
    var urgent: Bool
    var id: String { songId }
}

/// Disk cache of streamed songs (Caches/StreamCache/<account id>/). Songs are fetched in parallel with playback at low
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
        var urgent = false
    }

    private let root: URL
    /// The active account's folder; each account's database only indexes its own files.
    private(set) var directory: URL
    private let session: URLSession
    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var queued: [Job] = []
    private var active: [String: Task<Void, Never>] = [:]
    private var protectedIds: Set<String> = []
    private var limitBytes: Int = 2048 * 1_048_576
    private var database: DatabaseWriter?
    private let maxConcurrent = 3
    private var fractions: [String: Double] = [:]
    private var lastReport: TimeInterval = 0
    /// Until this uptime, background (non-urgent) jobs wait in the queue: a song is starting to stream.
    private var holdUntil: TimeInterval = 0
    /// Called (on any thread) whenever what is queued/downloading or its progress changes.
    var onActivity: (@Sendable ([CacheTransfer]) -> Void)?

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("StreamCache", isDirectory: true)
        directory = root
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup(root)
    }

    func configure(database: DatabaseWriter, accountId: String) {
        let directory = root.appendingPathComponent(safeFileComponent(accountId), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeLegacyRootFiles()
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
        self.directory = directory
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

    /// Account signed out or switched: stop every transfer and forget the old database (its pool gets closed).
    func deactivate() {
        lock.lock()
        let tasks = Array(active.values)
        active = [:]
        queued = []
        fractions = [:]
        urgentIds = []
        protectedIds = []
        index = [:]
        database = nil
        directory = root
        lock.unlock()
        tasks.forEach { $0.cancel() }
        report(force: true)
    }

    /// Files cached before the cache was split per account sit loose in the root; none of them is indexed anymore.
    private func removeLegacyRootFiles() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            try? fm.removeItem(at: item)
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
        let previousAccess = entry.lastAccess
        entry.lastAccess = Date()
        index[songId] = entry
        // Eviction reads the in-memory index, so the DB only needs a coarse timestamp (it seeds the next launch).
        guard entry.lastAccess.timeIntervalSince(previousAccess) > 600 else { return url }
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
        guard database != nil else { lock.unlock(); return }
        limitBytes = max(limitMB, 0) * 1_048_576
        let already = index[songId] != nil || active[songId] != nil || queued.contains { $0.songId == songId }
        if !already {
            queued.append(Job(songId: songId, url: url, quality: quality, ext: fileExtension))
        }
        lock.unlock()
        pump()
    }

    /// Like `cache`, but first in line and at normal network priority: AutoMix needs this song as a local file
    /// before its transition starts.
    func prioritize(songId: String, url: URL, quality: StreamQuality, fileExtension: String, limitMB: Int) {
        lock.lock()
        guard database != nil else { lock.unlock(); return }
        limitBytes = max(limitMB, 0) * 1_048_576
        if index[songId] == nil, active[songId] == nil {
            queued.removeAll { $0.songId == songId }
            var job = Job(songId: songId, url: url, quality: quality, ext: fileExtension)
            job.urgent = true
            queued.insert(job, at: 0)
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
        for id in cancelled.keys { active[id] = nil; fractions[id] = nil; urgentIds.remove(id) }
        lock.unlock()
        for task in cancelled.values { task.cancel() }
        report(force: true)
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
        fractions = [:]
        urgentIds = []
        let paths = index.values.map(\.relativePath)
        index = [:]
        lock.unlock()
        tasks.forEach { $0.cancel() }
        for p in paths { try? FileManager.default.removeItem(at: directory.appendingPathComponent(p)) }
        write { _ = try CachedSongRecord.deleteAll($0) }
    }

    // MARK: Internals

    /// Current transfers, in-flight first.
    func transfers() -> [CacheTransfer] {
        lock.lock()
        defer { lock.unlock() }
        let running = active.keys.map { id in
            CacheTransfer(songId: id, fraction: fractions[id], urgent: urgentIds.contains(id))
        }.sorted { ($0.urgent ? 0 : 1, $0.songId) < ($1.urgent ? 0 : 1, $1.songId) }
        let waiting = queued.map { CacheTransfer(songId: $0.songId, fraction: nil, urgent: $0.urgent) }
        return running + waiting
    }

    private var urgentIds: Set<String> = []

    private func report(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let due = force || now - lastReport > 0.25
        if due { lastReport = now }
        let handler = onActivity
        lock.unlock()
        guard due, let handler else { return }
        handler(transfers())
    }

    fileprivate func progress(_ songId: String, fraction: Double) {
        lock.lock()
        fractions[songId] = fraction
        lock.unlock()
        report()
    }

    /// Keep background downloads from starting for up to `seconds` (already running ones continue), so a song
    /// that is starting to stream is not competing with save-ahead for bandwidth. AutoMix's urgent jobs still run.
    func holdBackground(seconds: TimeInterval) {
        lock.lock()
        holdUntil = ProcessInfo.processInfo.systemUptime + seconds
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            // A little past the deadline so the re-pump sees the hold as over.
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.1) * 1_000_000_000))
            self?.pump()
        }
    }

    /// The song started playing: let held downloads go now.
    func releaseHold() {
        lock.lock()
        let wasHeld = holdUntil > ProcessInfo.processInfo.systemUptime
        holdUntil = 0
        lock.unlock()
        if wasHeld { pump() }
    }

    private func pump() {
        lock.lock()
        let held = ProcessInfo.processInfo.systemUptime < holdUntil
        while !queued.isEmpty, !held || queued[0].urgent,
              active.count < maxConcurrent || (queued[0].urgent && active.count < maxConcurrent + 1) {
            let job = queued.removeFirst()
            let task = Task.detached(priority: .utility) { [weak self] in
                await self?.run(job)
                return
            }
            active[job.songId] = task
            if job.urgent { urgentIds.insert(job.songId) }
        }
        lock.unlock()
        report(force: true)
    }

    private func run(_ job: Job) async {
        var request = URLRequest(url: job.url)
        request.networkServiceType = job.urgent ? .responsiveData : .background
        do {
            let tmp: URL
            if let videoId = YouTubeResourceLoader.videoId(in: job.url) {
                tmp = try await YouTubeAudioDownloader.download(videoId: videoId) { [weak self] fraction in
                    self?.progress(job.songId, fraction: fraction)
                }
            } else {
                let (file, response) = try await session.download(for: request,
                                                                   delegate: TransferProgress(cache: self, songId: job.songId))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let mime = http.mimeType?.lowercased() ?? ""
                // Subsonic reports errors as HTTP 200 with a JSON/XML body.
                if mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text") {
                    throw URLError(.cannotParseResponse)
                }
                tmp = file
            }
            try Task.checkCancellation()
            store(tmp: tmp, job: job)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            PlaybackLog.logger.error("Stream cache download failed for \(job.songId): \(error.localizedDescription)")
        }
        // A cancelled job was already unregistered by its canceller; a newer job for the same song may own the slots now.
        if !Task.isCancelled {
            lock.lock()
            active[job.songId] = nil
            fractions[job.songId] = nil
            urgentIds.remove(job.songId)
            lock.unlock()
        }
        pump()
        report(force: true)
    }

    private func store(tmp: URL, job: Job) {
        let name = "\(safeFileComponent(job.songId)).\(job.ext)"
        lock.lock()
        let configured = database != nil
        let dest = directory.appendingPathComponent(name)
        lock.unlock()
        guard configured else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
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

/// Forwards a cache download's progress (the async download API exposes the task here).
private final class TransferProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var cache: StreamCache?
    private let songId: String
    private var observation: NSKeyValueObservation?

    init(cache: StreamCache, songId: String) {
        self.cache = cache
        self.songId = songId
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            guard let self, progress.totalUnitCount > 0 else { return }
            self.cache?.progress(self.songId, fraction: progress.fractionCompleted)
        }
    }
}
