import Foundation
import GRDB

enum DownloadState: String, Codable, Sendable {
    case queued, downloading, completed, failed
}

struct DownloadStatus: Equatable, Sendable {
    var state: DownloadState
    /// 0...1 (stays 0 while the server doesn't report a length, e.g. transcoded downloads).
    var progress: Double
    var bytes: Int
    var errorMessage: String?
}

/// Offline downloads on a background URLSession (keeps going while the app is suspended and is re-attached
/// at launch). Files live in Application Support/Downloads/<songId>.<suffix>, excluded from backup.
@MainActor @Observable
final class DownloadManager {
    /// The app delegate's `handleEventsForBackgroundURLSession` stores its completion handler here.
    nonisolated(unsafe) static var backgroundCompletionHandler: (() -> Void)?
    static let sessionIdentifier = "com.knightabdo.knightmusic.downloads"
    static let maxConcurrent = 3

    /// songId -> status. Read `status(for:)` in views.
    private(set) var statuses: [String: DownloadStatus] = [:]

    var completedBytes: Int {
        statuses.values.filter { $0.state == .completed }.reduce(0) { $0 + $1.bytes }
    }
    var completedCount: Int { statuses.values.filter { $0.state == .completed }.count }
    var downloadedSongIds: Set<String> {
        Set(statuses.filter { $0.value.state == .completed }.map(\.key))
    }
    var activeCount: Int { statuses.values.filter { $0.state == .queued || $0.state == .downloading }.count }

    let directory: URL
    @ObservationIgnored var database: DatabaseWriter?
    @ObservationIgnored private var services = PlaybackServices()
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let delegate: DownloadSessionDelegate
    @ObservationIgnored private var paths: [String: String] = [:]
    @ObservationIgnored private var addedAt: [String: Date] = [:]
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var deferredWork: [@MainActor () -> Void] = []
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var lastProgressPublish: [String: TimeInterval] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        excludeFromBackup(dir)
        directory = dir
        delegate = DownloadSessionDelegate(directory: dir)
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.manager = self
    }

    /// Load persisted state, re-attach to tasks that kept running, and resume the queue.
    func configure(services: PlaybackServices, database: DatabaseWriter) {
        self.services = services
        self.database = database
        let rows: [DownloadRecord]
        do {
            rows = try database.read { try DownloadRecord.fetchAll($0) }
        } catch {
            PlaybackLog.logger.error("Loading downloads failed: \(error.localizedDescription)")
            rows = []
        }
        var stale: [String] = []
        for row in rows {
            addedAt[row.songId] = row.addedAt
            let state = DownloadState(rawValue: row.state) ?? .failed
            switch state {
            case .completed:
                if let rel = row.relativePath,
                   FileManager.default.fileExists(atPath: directory.appendingPathComponent(rel).path) {
                    paths[row.songId] = rel
                    statuses[row.songId] = DownloadStatus(state: .completed, progress: 1, bytes: row.bytes, errorMessage: nil)
                } else {
                    stale.append(row.songId)
                }
            case .queued, .downloading:
                paths[row.songId] = row.relativePath
                statuses[row.songId] = DownloadStatus(state: .queued, progress: 0, bytes: 0, errorMessage: nil)
                pending.append(row.songId)
            case .failed:
                paths[row.songId] = row.relativePath
                statuses[row.songId] = DownloadStatus(state: .failed, progress: 0, bytes: 0, errorMessage: row.errorMessage)
            }
        }
        if !stale.isEmpty { deleteRows(stale) }
        Task { await reattachAndStart() }
    }

    // MARK: Queries

    func status(for songId: String) -> DownloadStatus? { statuses[songId] }

    func isDownloaded(_ songId: String) -> Bool { statuses[songId]?.state == .completed }

    func localFileURL(for songId: String) -> URL? {
        guard statuses[songId]?.state == .completed, let rel = paths[songId] else { return nil }
        let url = directory.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func downloadedSongs() async -> [Song] {
        guard let database else { return [] }
        do {
            return try await database.read { db in
                try Song.fetchAll(db, sql: """
                    SELECT song.* FROM song JOIN download ON download.songId = song.id
                    WHERE download.state = 'completed' ORDER BY download.addedAt DESC
                    """)
            }
        } catch {
            PlaybackLog.logger.error("Fetching downloaded songs failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Commands

    func download(songs: [Song]) {
        let settings = services.settings
        for song in songs {
            if let state = statuses[song.id]?.state, state != .failed { continue }
            let ext = settings.downloadMaxBitRate > 0 ? (settings.downloadFormat ?? "mp3") : (song.suffix ?? "mp3")
            paths[song.id] = "\(safeFileComponent(song.id)).\(ext)"
            addedAt[song.id] = Date()
            statuses[song.id] = DownloadStatus(state: .queued, progress: 0, bytes: 0, errorMessage: nil)
            pending.removeAll { $0 == song.id }
            pending.append(song.id)
            persist(song.id)
        }
        startQueued()
    }

    func cancel(songIds: [String]) {
        let ids = songIds.filter { statuses[$0].map { $0.state != .completed } ?? false }
        remove(ids)
    }

    func cancel(songId: String) { cancel(songIds: [songId]) }

    func retryFailed() {
        for (id, status) in statuses where status.state == .failed {
            statuses[id] = DownloadStatus(state: .queued, progress: 0, bytes: 0, errorMessage: nil)
            pending.append(id)
            persist(id)
        }
        startQueued()
    }

    func delete(songIds: [String]) {
        remove(songIds)
    }

    func deleteAll() {
        remove(Array(statuses.keys))
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }

    /// Call when connectivity / settings / the URL provider changed so queued items can start.
    func networkDidChange() { startQueued() }

    // MARK: Internals

    private func reattachAndStart() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let (id, _) = DownloadSessionDelegate.parse(task.taskDescription),
                  let status = statuses[id], status.state == .queued || status.state == .downloading else {
                task.cancel()
                continue
            }
            active.insert(id)
            pending.removeAll { $0 == id }
            let expected = task.countOfBytesExpectedToReceive
            statuses[id] = DownloadStatus(state: .downloading,
                                          progress: expected > 0 ? Double(task.countOfBytesReceived) / Double(expected) : 0,
                                          bytes: Int(task.countOfBytesReceived), errorMessage: nil)
        }
        ready = true
        while !deferredWork.isEmpty {
            let work = deferredWork
            deferredWork = []
            work.forEach { $0() }
        }
        startQueued()
    }

    private func startQueued() {
        guard ready, let urls = services.urls, !services.isOffline else { return }
        let settings = services.settings
        while active.count < Self.maxConcurrent, !pending.isEmpty {
            let id = pending.removeFirst()
            guard statuses[id] != nil, let rel = paths[id] else { continue }
            let ext = (rel as NSString).pathExtension
            let url = settings.downloadMaxBitRate > 0
                ? urls.streamURL(songId: id, maxBitRate: settings.downloadMaxBitRate,
                                 format: settings.downloadFormat ?? ext, timeOffset: nil)
                : urls.downloadURL(songId: id)
            var request = URLRequest(url: url)
            request.allowsCellularAccess = settings.downloadOnCellular
            let task = session.downloadTask(with: request)
            task.taskDescription = "\(id)|\(rel)"
            task.resume()
            active.insert(id)
            statuses[id] = DownloadStatus(state: .downloading, progress: 0, bytes: 0, errorMessage: nil)
            persist(id)
        }
    }

    private func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        pending.removeAll { idSet.contains($0) }
        let wasActive = active.intersection(idSet)
        active.subtract(idSet)
        for id in ids {
            if let rel = paths[id] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(rel)) }
            paths[id] = nil
            statuses[id] = nil
            addedAt[id] = nil
            lastProgressPublish[id] = nil
        }
        deleteRows(ids)
        if !wasActive.isEmpty {
            Task {
                for task in await session.allTasks {
                    if let (id, _) = DownloadSessionDelegate.parse(task.taskDescription), wasActive.contains(id) {
                        task.cancel()
                    }
                }
            }
        }
        startQueued()
    }

    private func whenReady(_ work: @escaping @MainActor () -> Void) {
        if ready { work() } else { deferredWork.append(work) }
    }

    // Delegate entry points (already hopped to the main actor).

    fileprivate func progress(_ id: String, received: Int64, expected: Int64) {
        guard var status = statuses[id], status.state == .downloading || status.state == .queued else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastProgressPublish[id], now - last < 0.25, received != expected { return }
        lastProgressPublish[id] = now
        status.state = .downloading
        status.bytes = Int(received)
        status.progress = expected > 0 ? min(Double(received) / Double(expected), 1) : 0
        statuses[id] = status
    }

    fileprivate func finished(_ id: String, relativePath: String, bytes: Int, failure: String?) {
        whenReady { [self] in
            active.remove(id)
            lastProgressPublish[id] = nil
            guard statuses[id] != nil else {
                // Cancelled/deleted while finishing: discard the file.
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(relativePath))
                startQueued()
                return
            }
            if let failure {
                PlaybackLog.logger.error("Download failed (\(id)): \(failure)")
                statuses[id] = DownloadStatus(state: .failed, progress: 0, bytes: 0, errorMessage: failure)
            } else {
                paths[id] = relativePath
                statuses[id] = DownloadStatus(state: .completed, progress: 1, bytes: bytes, errorMessage: nil)
            }
            persist(id)
            startQueued()
        }
    }

    fileprivate func failed(_ id: String, message: String) {
        whenReady { [self] in
            guard let status = statuses[id], status.state != .completed else { return }
            active.remove(id)
            PlaybackLog.logger.error("Download failed (\(id)): \(message)")
            statuses[id] = DownloadStatus(state: .failed, progress: 0, bytes: 0, errorMessage: message)
            persist(id)
            startQueued()
        }
    }

    fileprivate func sessionFinishedEvents() {
        DownloadManager.backgroundCompletionHandler?()
        DownloadManager.backgroundCompletionHandler = nil
    }

    // MARK: Persistence

    private func persist(_ id: String) {
        guard let database, let status = statuses[id] else { return }
        let record = DownloadRecord(songId: id, state: status.state.rawValue, progress: status.progress,
                                    bytes: status.bytes, relativePath: paths[id],
                                    addedAt: addedAt[id] ?? Date(), errorMessage: status.errorMessage)
        Task {
            do {
                try await database.write { try record.save($0) }
            } catch {
                PlaybackLog.logger.error("Persisting download failed: \(error.localizedDescription)")
            }
        }
    }

    private func deleteRows(_ ids: [String]) {
        guard let database else { return }
        Task {
            do {
                try await database.write { _ = try DownloadRecord.deleteAll($0, keys: ids) }
            } catch {
                PlaybackLog.logger.error("Deleting download rows failed: \(error.localizedDescription)")
            }
        }
    }
}

/// URLSession delegate (called on a background queue). Moves finished files into place synchronously —
/// required, the temporary file disappears when the callback returns — then reports to the manager.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func parse(_ description: String?) -> (id: String, relativePath: String)? {
        guard let description, let bar = description.lastIndex(of: "|") else { return nil }
        return (String(description[..<bar]), String(description[description.index(after: bar)...]))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, _) = Self.parse(downloadTask.taskDescription) else { return }
        let manager = self.manager
        Task { @MainActor in
            manager?.progress(id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, rel) = Self.parse(downloadTask.taskDescription) else { return }
        var failure: String?
        var bytes = 0
        let http = downloadTask.response as? HTTPURLResponse
        let mime = http?.mimeType?.lowercased() ?? ""
        if http?.statusCode != 200 {
            failure = "Server returned status \(http?.statusCode ?? 0)"
        } else if mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text") {
            // Subsonic reports errors as HTTP 200 with a JSON/XML body.
            failure = "The server returned an error instead of audio"
        } else {
            let dest = directory.appendingPathComponent(rel)
            let fm = FileManager.default
            do {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: location, to: dest)
                excludeFromBackup(dest)
                bytes = (try fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
                if bytes == 0 {
                    try? fm.removeItem(at: dest)
                    failure = "The downloaded file was empty"
                }
            } catch {
                failure = "Couldn\u{2019}t save the file: \(error.localizedDescription)"
            }
        }
        let manager = self.manager
        let message = failure
        let size = bytes
        Task { @MainActor in
            manager?.finished(id, relativePath: rel, bytes: size, failure: message)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (id, _) = Self.parse(task.taskDescription) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let manager = self.manager
        let message = error.localizedDescription
        Task { @MainActor in
            manager?.failed(id, message: message)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let manager = self.manager
        Task { @MainActor in
            if let manager { manager.sessionFinishedEvents() } else {
                DownloadManager.backgroundCompletionHandler?()
                DownloadManager.backgroundCompletionHandler = nil
            }
        }
    }
}
