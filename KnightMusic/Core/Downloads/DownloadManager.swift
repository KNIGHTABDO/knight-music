import Foundation
import GRDB
import UIKit
import AVFoundation

private struct DownloadRequestSnapshot: Sendable {
    var bitRate: Int
    var format: String
    var allowsCellular: Bool
}

enum DownloadState: String, Codable, Sendable {
    case queued, downloading, completed, failed, needsRetry, recoveryBlocked
}

struct DownloadStatus: Equatable, Sendable {
    var state: DownloadState
    /// 0...1 (stays 0 while the server doesn't report a length, e.g. transcoded downloads).
    var progress: Double
    var bytes: Int
    var errorMessage: String?
}

/// Offline downloads on a background URLSession (keeps going while the app is suspended and is re-attached
/// at launch). Each account stores completed files under its own folder, excluded from backup.
@MainActor @Observable
final class DownloadManager {
    static let sessionIdentifier = "com.knightabdo.knightmusic.downloads"
    /// Ordinary albums are handed to iOS in one foreground burst. The system still
    /// controls when each request runs; this only avoids app-wake refill cycles.
    static let maxForegroundAdmission = 16
    static let maxBackgroundRefill = 16
    static let unverifiableMessage = "Downloaded audio could not be verified"
    nonisolated static let storageMessage = "Not enough free storage to download"
    static let minimumFreeBytes: Int64 = 500_000_000
    static let maxTransientRetries = 4

    /// songId -> status. Read `status(for:)` in views.
    private(set) var statuses: [String: DownloadStatus] = [:]

    var completedBytes: Int {
        statuses.values.filter { $0.state == .completed }.reduce(0) { $0 + $1.bytes }
    }
    var completedCount: Int { statuses.values.filter { $0.state == .completed }.count }
    var downloadedSongIds: Set<String> {
        Set(statuses.filter { $0.value.state == .completed }.map(\.key))
    }

    /// Downloaded plus still queued or in flight: what this device means to keep offline.
    var wantedSongIds: Set<String> {
        Set(statuses.filter { [.completed, .queued, .downloading, .needsRetry].contains($0.value.state) }.map(\.key))
    }

    let directory: URL
    @ObservationIgnored var database: DatabaseWriter?
    @ObservationIgnored private var services = PlaybackServices()
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let delegate: DownloadSessionDelegate
    @ObservationIgnored private var paths: [String: String] = [:]
    @ObservationIgnored private var addedAt: [String: Date] = [:]
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var active: [String: String] = [:]
    @ObservationIgnored private var deferredWork: [@MainActor () -> Void] = []
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var receiptsReconciled = false
    @ObservationIgnored private var lastProgressPublish: [String: TimeInterval] = [:]
    @ObservationIgnored private var attempts: [String: String] = [:]
    @ObservationIgnored private var attemptEpochs: [String: UInt64] = [:]
    @ObservationIgnored private var verifyingAttempts: [String: UInt64] = [:]
    @ObservationIgnored private var requestSnapshots: [String: DownloadRequestSnapshot] = [:]
    @ObservationIgnored private var awaitingAcceptance: [String: String] = [:]
    @ObservationIgnored private var ownerId: String?
    @ObservationIgnored private var configurationEpoch: UInt64 = 0
    @ObservationIgnored private var persistenceTail: Task<Void, Never>?
    @ObservationIgnored private var recoveryEpoch: UInt64?
    @ObservationIgnored private var transientRetries: [String: Int] = [:]
    @ObservationIgnored private var retryWaiting: Set<String> = []
    @ObservationIgnored private var optedOut: Set<String> = []

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
    func configure(services: PlaybackServices, database: DatabaseWriter, ownerId: UUID) {
        configurationEpoch &+= 1
        if self.ownerId != ownerId.uuidString {
            self.ownerId = ownerId.uuidString
            statuses.removeAll()
            paths.removeAll()
            addedAt.removeAll()
            pending.removeAll()
            active.removeAll()
            attempts.removeAll()
            attemptEpochs.removeAll()
            verifyingAttempts.removeAll()
            requestSnapshots.removeAll()
            awaitingAcceptance.removeAll()
            transientRetries.removeAll()
            retryWaiting.removeAll()
            optedOut = Set(UserDefaults.standard.stringArray(forKey: "downloads.optOut.\(ownerId.uuidString)") ?? [])
            ready = false
            receiptsReconciled = false
        }
        self.services = services
        self.database = database
        let epoch = configurationEpoch
        let rows: [DownloadRecord]
        ready = false
        receiptsReconciled = false
        do {
            rows = try database.read { try DownloadRecord.fetchAll($0) }
        } catch {
            PlaybackLog.logger.error("Loading downloads failed: \(error.localizedDescription)")
            return
        }
        for row in rows {
            addedAt[row.songId] = row.addedAt
            attempts[row.songId] = row.attemptId
            if let bitRate = row.requestedBitRate, let format = row.requestedFormat {
                requestSnapshots[row.songId] = DownloadRequestSnapshot(bitRate: bitRate, format: format,
                                                                         allowsCellular: row.allowsCellular ?? true)
            }
            let state = DownloadState(rawValue: row.state) ?? .failed
            switch state {
            case .completed:
                if let rel = row.relativePath, rel.hasPrefix(ownerId.uuidString + "/"),
                   let attempt = row.attemptId, rel.contains(attempt),
                   FileManager.default.fileExists(atPath: directory.appendingPathComponent(rel).path) {
                    attempts[row.songId] = attempt
                    paths[row.songId] = rel
                    statuses[row.songId] = DownloadStatus(state: .completed, progress: 1, bytes: row.bytes, errorMessage: nil)
                } else {
                    paths[row.songId] = row.relativePath
                    statuses[row.songId] = DownloadStatus(state: .needsRetry, progress: 0, bytes: 0,
                                                           errorMessage: "Save a new offline copy to verify this account’s audio")
                }
            case .queued, .downloading:
                paths[row.songId] = row.relativePath
                if let attempt = row.attemptId, let rel = row.relativePath,
                   rel.hasPrefix(ownerId.uuidString + "/"), rel.contains(attempt) {
                    attempts[row.songId] = attempt
                    statuses[row.songId] = DownloadStatus(state: .queued, progress: 0, bytes: 0, errorMessage: nil)
                    if !pending.contains(row.songId) { pending.append(row.songId) }
                } else {
                    statuses[row.songId] = DownloadStatus(state: .needsRetry, progress: 0, bytes: 0,
                                                           errorMessage: "Retry to create an account-scoped download")
                }
            case .failed:
                paths[row.songId] = row.relativePath
                statuses[row.songId] = DownloadStatus(state: .failed, progress: 0, bytes: 0, errorMessage: row.errorMessage)
            case .needsRetry:
                paths[row.songId] = row.relativePath
                statuses[row.songId] = DownloadStatus(state: .needsRetry, progress: 0, bytes: 0,
                                                       errorMessage: "Retry to create an account-scoped download")
            case .recoveryBlocked:
                statuses[row.songId] = DownloadStatus(state: .needsRetry, progress: 0, bytes: 0,
                                                       errorMessage: "Retry to create an account-scoped download")
            }
        }
        Task {
            await recoverTransfers(ownerId: ownerId.uuidString, epoch: epoch)
            guard self.configurationEpoch == epoch, self.ownerId == ownerId.uuidString else { return }
            // Once per launch: a download that fails again stays failed until the next launch.
            if !services.isOffline, statuses.values.contains(where: { $0.state == .failed }) {
                retryFailed(automatic: true)
            }
        }
    }

    func deactivate() {
        configurationEpoch &+= 1
        ownerId = nil
        database = nil
        statuses.removeAll()
        paths.removeAll()
        addedAt.removeAll()
        pending.removeAll()
        active.removeAll()
        attempts.removeAll()
        attemptEpochs.removeAll()
        verifyingAttempts.removeAll()
        requestSnapshots.removeAll()
        awaitingAcceptance.removeAll()
        transientRetries.removeAll()
        retryWaiting.removeAll()
        optedOut.removeAll()
        ready = false
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
        guard let database, let ownerId else { return [] }
        let epoch = configurationEpoch
        do {
            let songs = try await database.read { db in
                try Song.fetchAll(db, sql: """
                    SELECT song.* FROM song JOIN download ON download.songId = song.id
                    WHERE download.state = 'completed'
                      AND download.relativePath GLOB '????????-????-????-????-????????????/*'
                      AND download.relativePath LIKE ?
                    ORDER BY download.addedAt DESC
                    """, arguments: [ownerId + "/%"])
            }
            guard self.ownerId == ownerId, configurationEpoch == epoch else { return [] }
            return songs
        } catch {
            PlaybackLog.logger.error("Fetching downloaded songs failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Commands

    /// `automatic` is true for auto-download lists: songs the user removed are not brought back.
    func download(songs: [Song], automatic: Bool = false) {
        guard let ownerId, let database else { return }
        let settings = services.settings
        var captured: [String: String] = [:]
        // YouTube songs are saved with "Add to Navidrome" instead; offline copies live in the stream cache.
        for song in songs where !song.isYouTube {
            if automatic, optedOut.contains(song.id) { continue }
            if !automatic, optedOut.remove(song.id) != nil { saveOptOut() }
            if statuses[song.id]?.state == .recoveryBlocked {
                retryRecovery()
                continue
            }
            if let state = statuses[song.id]?.state,
               state != .failed && state != .needsRetry { continue }
            // AVFoundation cannot read Ogg/Opus & co., so those are never saved as-is: transcode to MP3 instead.
            var bitRate = settings.downloadMaxBitRate
            var format = bitRate > 0 ? (settings.downloadFormat ?? "mp3") : (song.suffix ?? "mp3")
            if bitRate > 0, Self.unplayableFormats.contains(format.lowercased()) {
                format = "mp3"
            } else if bitRate == 0, !Self.playableFormats.contains(format.lowercased()) {
                bitRate = 256
                format = "mp3"
            }
            let ext = format.range(of: #"^[A-Za-z0-9]{1,16}$"#, options: .regularExpression) == nil ? "mp3" : format
            let attempt = UUID().uuidString
            attempts[song.id] = attempt
            requestSnapshots[song.id] = DownloadRequestSnapshot(
                bitRate: bitRate,
                format: ext,
                allowsCellular: settings.downloadOnCellular
            )
            transientRetries[song.id] = nil
            retryWaiting.remove(song.id)
            paths[song.id] = "\(ownerId)/\(attempt).\(ext)"
            addedAt[song.id] = Date()
            statuses[song.id] = DownloadStatus(state: .queued, progress: 0, bytes: 0, errorMessage: nil)
            pending.removeAll { $0 == song.id }
            pending.append(song.id)
            awaitingAcceptance[song.id] = attempt
            captured[song.id] = attempt
        }
        guard !captured.isEmpty else { return }
        let admittedAttempts = captured
        let epoch = configurationEpoch
        let records = captured.compactMap { id, attempt -> DownloadRecord? in
            guard attempts[id] == attempt else { return nil }
            guard let status = statuses[id] else { return nil }
            return DownloadRecord(songId: id, state: status.state.rawValue, progress: status.progress,
                                  bytes: status.bytes, relativePath: paths[id], addedAt: addedAt[id] ?? Date(),
                                  errorMessage: nil, attemptId: attempts[id],
                                  requestedBitRate: requestSnapshots[id]?.bitRate,
                                  requestedFormat: requestSnapshots[id]?.format,
                                  allowsCellular: requestSnapshots[id]?.allowsCellular)
        }
        let capturedOwner = ownerId
        let previous = persistenceTail
        let operation = Task { [weak self] in
            await previous?.value
            do {
                try await database.write { db in for record in records { try record.save(db) } }
                await MainActor.run {
                    guard let self else { return }
                    guard self.configurationEpoch == epoch, self.ownerId == capturedOwner else { return }
                    for (id, attempt) in admittedAttempts where self.awaitingAcceptance[id] == attempt {
                        self.awaitingAcceptance[id] = nil
                    }
                    if self.receiptsReconciled { self.startQueued() }
                    else { Task { await self.recoverTransfers(ownerId: capturedOwner, epoch: epoch) } }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard self.configurationEpoch == epoch, self.ownerId == capturedOwner else { return }
                    for (id, attempt) in admittedAttempts where self.awaitingAcceptance[id] == attempt {
                        self.awaitingAcceptance[id] = nil
                        self.pending.removeAll { $0 == id }
                        self.statuses[id] = DownloadStatus(state: .failed, progress: 0, bytes: 0,
                                                            errorMessage: "Couldn’t save download request")
                    }
                }
                PlaybackLog.logger.error("Accepting downloads failed: \(error.localizedDescription)")
            }
        }
        persistenceTail = Task { await operation.value }
    }

    func cancel(songIds: [String]) {
        let ids = songIds.filter { statuses[$0].map { $0.state != .completed } ?? false }
        remove(ids)
    }

    func cancel(songId: String) { cancel(songIds: [songId]) }

    func retryFailed(includeLegacy: Bool = false, automatic: Bool = false) {
        guard let database, let ownerId else { return }
        let epoch = configurationEpoch
        let ids = statuses.compactMap { id, status -> String? in
            if automatic, status.state == .failed, Self.isPermanentFailure(status.errorMessage) { return nil }
            return status.state == .failed || (includeLegacy && status.state == .needsRetry) ? id : nil
        }
        let attempts = Dictionary(uniqueKeysWithValues: ids.compactMap { id in self.attempts[id].map { (id, $0) } })
        guard !ids.isEmpty else { return }
        Task {
            do {
                let songs = try await database.read { db in
                    try LibraryQueries.songs(db, ids: ids)
                }
                guard self.ownerId == ownerId, self.configurationEpoch == epoch else { return }
                let eligible = songs.filter {
                    let state = self.statuses[$0.id]?.state
                    return self.attempts[$0.id] == attempts[$0.id]
                        && (state == .failed || (includeLegacy && state == .needsRetry))
                }
                self.download(songs: eligible)
            } catch { PlaybackLog.logger.error("Reading failed downloads for retry failed: \(error.localizedDescription)") }
        }
    }

    func delete(songIds: [String]) {
        remove(songIds)
    }

    func deleteAll() {
        remove(Array(statuses.keys))
    }

    /// Retries one failed or legacy download on demand.
    func retry(songId: String) {
        guard let database, let ownerId, let state = statuses[songId]?.state,
              state == .failed || state == .needsRetry else { return }
        let epoch = configurationEpoch
        Task {
            do {
                let songs = try await database.read { try LibraryQueries.songs($0, ids: [songId]) }
                guard self.ownerId == ownerId, self.configurationEpoch == epoch else { return }
                self.download(songs: songs)
            } catch { PlaybackLog.logger.error("Reading song for retry failed: \(error.localizedDescription)") }
        }
    }

    /// Resolves once every queued database write (deletes, completions) has been committed.
    func settled() async { await persistenceTail?.value }

    /// Call when connectivity / settings / the URL provider changed so queued items can start.
    func networkDidChange() {
        flushRetryWaiting()
        guard receiptsReconciled else {
            retryRecovery()
            return
        }
        startQueued()
    }

    func retryRecovery() {
        guard let ownerId else { return }
        let epoch = configurationEpoch
        Task { await recoverTransfers(ownerId: ownerId, epoch: epoch) }
    }

    // MARK: Internals

    private func recoverTransfers(ownerId: String, epoch: UInt64) async {
        guard self.ownerId == ownerId, configurationEpoch == epoch,
              recoveryEpoch != epoch else { return }
        recoveryEpoch = epoch
        defer { if recoveryEpoch == epoch { recoveryEpoch = nil } }
        guard await reconcileReceipts(ownerId: ownerId, epoch: epoch) else {
            markRecoveryBlocked(ownerId: ownerId, epoch: epoch)
            return
        }
        guard self.ownerId == ownerId, configurationEpoch == epoch else { return }
        await reattachAndStart()
        guard self.ownerId == ownerId, configurationEpoch == epoch else { return }
        guard await reconcileReceipts(ownerId: ownerId, epoch: epoch) else {
            markRecoveryBlocked(ownerId: ownerId, epoch: epoch)
            return
        }
        guard self.ownerId == ownerId, configurationEpoch == epoch else { return }
        receiptsReconciled = true
        startQueued()
    }

    private func markRecoveryBlocked(ownerId: String, epoch: UInt64) {
        guard self.ownerId == ownerId, configurationEpoch == epoch else { return }
        let blockedIds = statuses.compactMap { id, status in
            status.state == .queued || status.state == .downloading ? id : nil
        }
        for id in blockedIds {
            guard let status = statuses[id] else { continue }
            statuses[id] = DownloadStatus(state: .recoveryBlocked, progress: status.progress,
                                           bytes: status.bytes,
                                           errorMessage: "Waiting to recover the saved download; retry when storage is available")
        }
    }

    private func reconcileReceipts(ownerId: String, epoch: UInt64) async -> Bool {
        guard self.ownerId == ownerId, configurationEpoch == epoch, let database else { return false }
        let receipts: [TransferReceipt]
        do { receipts = try TransferReceiptStore.readAll(ownerId: ownerId, under: directory) }
        catch {
            PlaybackLog.logger.error("Reading download receipts failed: \(error.localizedDescription)")
            return false
        }
        for receipt in receipts {
            guard self.ownerId == ownerId, configurationEpoch == epoch else { return false }
            let row: DownloadRecord?
            do { row = try await database.read { db in try DownloadRecord.fetchOne(db, key: receipt.songId) } }
            catch {
                PlaybackLog.logger.error("Checking download receipt ownership failed: \(error.localizedDescription)")
                return false
            }
            guard self.ownerId == ownerId, configurationEpoch == epoch else { return false }
            guard let row, row.attemptId == receipt.attemptId else {
                if let stagedPath = receipt.stagedPath {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(stagedPath))
                }
                TransferReceiptStore.remove(receipt, under: directory)
                continue
            }
            if let currentAttempt = attempts[receipt.songId], currentAttempt != receipt.attemptId { continue }
            attempts[receipt.songId] = receipt.attemptId
            attemptEpochs[receipt.songId] = receipt.epoch
            paths[receipt.songId] = receipt.relativePath
            pending.removeAll { $0 == receipt.songId }
            if row.state == DownloadState.completed.rawValue,
               statuses[receipt.songId]?.state == .completed {
                TransferReceiptStore.remove(receipt, under: directory)
                continue
            }
            if receipt.outcome == .staged {
                statuses[receipt.songId] = DownloadStatus(state: .downloading, progress: 1,
                                                          bytes: receipt.bytes, errorMessage: nil)
                finalize(receipt, epoch: receipt.epoch)
            } else {
                active[receipt.songId] = nil
                let reason = receipt.message ?? (receipt.outcome == .cancelled ? "Cancelled" : "Transfer failed")
                statuses[receipt.songId] = DownloadStatus(state: .failed, progress: 0, bytes: 0,
                                                          errorMessage: reason)
                do {
                    try await database.write { db in
                        try db.execute(sql: "UPDATE download SET state = ?, progress = 0, bytes = 0, errorMessage = ? WHERE songId = ? AND attemptId = ?",
                                       arguments: [DownloadState.failed.rawValue, reason, receipt.songId, receipt.attemptId])
                    }
                    guard self.ownerId == ownerId, configurationEpoch == epoch else { return false }
                    TransferReceiptStore.remove(receipt, under: directory)
                } catch {
                    PlaybackLog.logger.error("Recording failed download receipt failed: \(error.localizedDescription)")
                    return false
                }
            }
        }
        return true
    }

    private func reattachAndStart() async {
        guard let capturedOwner = ownerId else { return }
        let capturedEpoch = configurationEpoch
        let tasks = await session.allTasks
        guard ownerId == capturedOwner, configurationEpoch == capturedEpoch else { return }
        for task in tasks {
            guard ownerId == capturedOwner, configurationEpoch == capturedEpoch,
                  let parsed = DownloadSessionDelegate.parse(task.taskDescription), parsed.ownerId == capturedOwner else {
                continue
            }
            let id = parsed.id
            // The song was removed before this launch finished attaching: stop its orphaned transfer.
            if statuses[id] == nil { task.cancel(); continue }
            guard let status = statuses[id], (status.state == .queued || status.state == .downloading || status.state == .recoveryBlocked),
                  attempts[id] == nil || attempts[id] == parsed.attemptId else { continue }
            attempts[id] = parsed.attemptId
            attemptEpochs[id] = parsed.epoch
            active[id] = parsed.attemptId
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
    }

    private func startQueued() {
        guard ready, receiptsReconciled, let urls = services.urls, !services.isOffline else { return }
        guard let ownerId else { return }
        // A task bakes its host (LAN vs Tailscale) in at creation: wait until the address has settled.
        if services.isResolvingAddress?() == true { return }
        if !pending.isEmpty, let free = Self.availableCapacity(), free < Self.minimumFreeBytes {
            for id in pending where statuses[id]?.state == .queued && statuses[id]?.errorMessage != Self.storageMessage {
                statuses[id]?.errorMessage = Self.storageMessage
            }
            Log.downloads.error("Download queue paused: only \(free / 1_000_000) MB free")
            return
        }
        let foregroundLimit = min(Self.maxForegroundAdmission, pending.count + active.count)
        let limit = UIApplication.shared.applicationState == .active
            ? foregroundLimit : min(Self.maxBackgroundRefill, pending.count + active.count)
        while active.count < limit, !pending.isEmpty {
            let id = pending.removeFirst()
            guard awaitingAcceptance[id] == nil else { pending.append(id); break }
            guard active[id] == nil else { continue }
            guard statuses[id] != nil, let rel = paths[id] else { continue }
            let snapshot = requestSnapshots[id] ?? DownloadRequestSnapshot(
                bitRate: services.settings.downloadMaxBitRate,
                format: services.settings.downloadFormat ?? (rel as NSString).pathExtension,
                allowsCellular: services.settings.downloadOnCellular
            )
            requestSnapshots[id] = snapshot
            let url = snapshot.bitRate > 0
                ? urls.streamURL(songId: id, maxBitRate: snapshot.bitRate,
                                 format: snapshot.format, timeOffset: nil)
                : urls.downloadURL(songId: id)
            var request = URLRequest(url: url)
            request.allowsCellularAccess = snapshot.allowsCellular
            // Personal Hotspot and Low Data Mode count as expensive/constrained, not cellular.
            request.allowsExpensiveNetworkAccess = snapshot.allowsCellular
            request.allowsConstrainedNetworkAccess = snapshot.allowsCellular
            let task = session.downloadTask(with: request)
            let attempt = attempts[id] ?? UUID().uuidString
            attempts[id] = attempt
            attemptEpochs[id] = configurationEpoch
            task.taskDescription = TransferTaskIdentity(ownerId: ownerId, epoch: configurationEpoch,
                                                        attemptId: attempt, songId: id, relativePath: rel).taskDescription
            task.resume()
            active[id] = attempt
            statuses[id] = DownloadStatus(state: .downloading, progress: 0, bytes: 0, errorMessage: nil)
            persist(id)
        }
    }

    private func remove(_ songIds: [String]) {
        let ids = Set(songIds)
        guard !ids.isEmpty else { return }
        pending.removeAll { ids.contains($0) }
        let oldAttempts = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            attempts[id].map { (id, $0) }
        })
        let legacyPaths: [String: String] = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            guard attempts[id] == nil, let path = paths[id] else { return nil }
            return (id, path)
        })
        let capturedOwner = ownerId
        // User removals must not be undone by auto-download lists.
        optedOut.formUnion(ids)
        saveOptOut()
        var doomedFiles: [URL] = []
        for id in ids {
            if let rel = paths[id], let ownerId, rel.hasPrefix(ownerId + "/"),
               let attempt = oldAttempts[id], rel.contains(attempt) {
                doomedFiles.append(directory.appendingPathComponent(rel))
            } else if oldAttempts[id] == nil, let rel = paths[id], !rel.isEmpty,
                      !rel.hasPrefix("/"), !rel.contains("..") {
                doomedFiles.append(directory.appendingPathComponent(rel))
            }
            transientRetries[id] = nil
            retryWaiting.remove(id)
            paths[id] = nil
            statuses[id] = nil
            addedAt[id] = nil
            lastProgressPublish[id] = nil
            attempts[id] = nil
            attemptEpochs[id] = nil
            requestSnapshots[id] = nil
            awaitingAcceptance[id] = nil
            active[id] = nil
        }
        if let database, capturedOwner != nil {
            deleteRows(ids, attempts: oldAttempts, legacyPaths: legacyPaths, database: database)
        }
        if !oldAttempts.isEmpty {
            Task {
                for task in await session.allTasks {
                    guard let capturedOwner,
                          let parsed = DownloadSessionDelegate.parse(task.taskDescription), parsed.ownerId == capturedOwner,
                          oldAttempts[parsed.id] == parsed.attemptId else { continue }
                    task.cancel()
                }
            }
        }
        if !doomedFiles.isEmpty {
            Task.detached(priority: .utility) {
                for url in doomedFiles { try? FileManager.default.removeItem(at: url) }
            }
        }
        startQueued()
    }

    private func whenReady(_ work: @escaping @MainActor () -> Void) {
        if ready { work() } else { deferredWork.append(work) }
    }

    // Delegate entry points (already hopped to the main actor).

    func progress(_ id: String, owner: String, epoch: UInt64, attempt: String,
                              received: Int64, expected: Int64) {
        guard owner == ownerId, attemptEpochs[id] == epoch, attempts[id] == attempt,
              active[id] == attempt else { return }
        guard var status = statuses[id], status.state == .downloading || status.state == .queued else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastProgressPublish[id], now - last < 0.25, received != expected { return }
        lastProgressPublish[id] = now
        status.state = .downloading
        status.bytes = Int(received)
        status.progress = expected > 0 ? min(Double(received) / Double(expected), 1) : 0
        statuses[id] = status
    }

    func finished(_ receipt: TransferReceipt, epoch: UInt64) {
        let id = receipt.songId
        guard receipt.ownerId == ownerId, attempts[id] == receipt.attemptId else { return }
        if attemptEpochs[id] == nil {
            attemptEpochs[id] = epoch
            active[id] = receipt.attemptId
            pending.removeAll { $0 == id }
        }
        guard attemptEpochs[id] == epoch,
              active[id] == receipt.attemptId, statuses[id] != nil else { return }
        whenReady { [self] in
            guard self.ownerId == receipt.ownerId, self.attemptEpochs[id] == epoch,
                  self.attempts[id] == receipt.attemptId, self.active[id] == receipt.attemptId else { return }
            active[id] = nil
            lastProgressPublish[id] = nil
            guard statuses[id] != nil else {
                startQueued()
                return
            }
            if receipt.outcome == .failed, Self.isTransient(receipt.errorCode),
               (transientRetries[id] ?? 0) < Self.maxTransientRetries {
                scheduleRetry(id, receipt: receipt)
                return
            }
            if receipt.outcome != .staged {
                let failure = receipt.message ?? "Transfer did not complete"
                PlaybackLog.logger.error("Download failed (\(id)): \(failure)")
                statuses[id] = DownloadStatus(state: .failed, progress: 0, bytes: 0, errorMessage: failure)
                persist(id)
                startQueued()
            } else {
                statuses[id] = DownloadStatus(state: .downloading, progress: 1, bytes: receipt.bytes, errorMessage: nil)
                finalize(receipt, epoch: epoch)
            }
        }
    }

    func receiptWriteFailed(owner: String, epoch: UInt64, attempt: String, songId: String,
                                        message: String) {
        guard owner == ownerId, attempts[songId] == attempt else { return }
        if attemptEpochs[songId] == nil { attemptEpochs[songId] = epoch }
        guard attemptEpochs[songId] == epoch else { return }
        active[songId] = nil
        statuses[songId] = DownloadStatus(state: .failed, progress: 0, bytes: 0,
                                           errorMessage: "Could not record transfer result: \(message)")
        persist(songId)
        startQueued()
    }

    private func finalize(_ receipt: TransferReceipt, epoch: UInt64) {
        guard let database, let stagedPath = receipt.stagedPath else { return }
        let owner = receipt.ownerId
        let id = receipt.songId
        let capturedConfiguration = configurationEpoch
        guard verifyingAttempts[receipt.attemptId] != capturedConfiguration else { return }
        verifyingAttempts[receipt.attemptId] = capturedConfiguration
        let root = directory
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.verifyingAttempts[receipt.attemptId] == capturedConfiguration {
                    self.verifyingAttempts[receipt.attemptId] = nil
                }
            }
            var verified = false
            do {
                guard self.configurationEpoch == capturedConfiguration,
                      self.ownerId == owner, self.attemptEpochs[id] == epoch,
                      self.attempts[id] == receipt.attemptId else { return }
                let byteCount = try await Task.detached(priority: .utility) { () throws -> Int in
                    let stage = root.appendingPathComponent(stagedPath)
                    let final = root.appendingPathComponent(receipt.relativePath)
                    try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let source = FileManager.default.fileExists(atPath: final.path) ? final : stage
                    let audio = try AVAudioFile(forReading: source)
                    guard audio.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let bytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
                    guard bytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    // Each attempt has a unique immutable path; no valid prior copy is replaced.
                    if source == stage && !FileManager.default.fileExists(atPath: final.path) {
                        try FileManager.default.moveItem(at: stage, to: final)
                    }
                    return bytes
                }.value
                verified = true
                guard self.configurationEpoch == capturedConfiguration,
                      self.ownerId == owner, self.attemptEpochs[id] == epoch,
                      self.attempts[id] == receipt.attemptId else { return }
                let record = DownloadRecord(songId: id, state: DownloadState.completed.rawValue, progress: 1,
                                            bytes: byteCount, relativePath: receipt.relativePath,
                                            addedAt: self.addedAt[id] ?? Date(), errorMessage: nil,
                                            attemptId: receipt.attemptId,
                                            requestedBitRate: self.requestSnapshots[id]?.bitRate,
                                            requestedFormat: self.requestSnapshots[id]?.format,
                                            allowsCellular: self.requestSnapshots[id]?.allowsCellular)
                let previous = self.persistenceTail
                let dbCommit = Task { () throws -> Void in
                    await previous?.value
                    try await database.write { db in
                        try db.execute(sql: """
                            UPDATE download SET state = ?, progress = ?, bytes = ?, relativePath = ?, addedAt = ?,
                                errorMessage = ?, requestedBitRate = ?, requestedFormat = ?, allowsCellular = ?
                            WHERE songId = ? AND attemptId = ?
                            """, arguments: [record.state, record.progress, record.bytes, record.relativePath,
                                            record.addedAt, record.errorMessage, record.requestedBitRate,
                                            record.requestedFormat, record.allowsCellular, id, receipt.attemptId])
                        guard db.changesCount > 0 else { throw CocoaError(.userCancelled) }
                    }
                }
                self.persistenceTail = Task { try? await dbCommit.value }
                try await dbCommit.value
                guard self.configurationEpoch == capturedConfiguration,
                      self.ownerId == owner, self.attemptEpochs[id] == epoch,
                      self.attempts[id] == receipt.attemptId else { return }
                self.paths[id] = receipt.relativePath
                self.active[id] = nil
                self.transientRetries[id] = nil
                self.statuses[id] = DownloadStatus(state: .completed, progress: 1, bytes: byteCount, errorMessage: nil)
                TransferReceiptStore.remove(receipt, under: self.directory)
                self.startQueued()
            } catch {
                PlaybackLog.logger.error("Finalizing download failed: \(error.localizedDescription)")
                guard self.configurationEpoch == capturedConfiguration, self.ownerId == owner,
                      self.attemptEpochs[id] == epoch, self.attempts[id] == receipt.attemptId else { return }
                self.active[id] = nil
                if verified {
                    self.statuses[id] = DownloadStatus(state: .recoveryBlocked, progress: 1, bytes: receipt.bytes,
                                                       errorMessage: "Audio is saved. Retry to finish making it available offline.")
                } else {
                    self.statuses[id] = DownloadStatus(state: .failed, progress: 0, bytes: 0,
                                                       errorMessage: Self.unverifiableMessage)
                    self.persist(id)
                }
                self.startQueued()
            }
        }
    }

    // MARK: Transient failures, storage, account cleanup

    private static let playableFormats: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "caf", "mp4"]
    private static let unplayableFormats: Set<String> = ["opus", "ogg", "oga"]

    static func isTransient(_ code: Int?) -> Bool {
        guard let code else { return false }
        if code >= 500 && code <= 599 || code == 408 || code == 429 { return true }
        return [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed].contains(code)
    }

    private static func isPermanentFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        return message == unverifiableMessage || message == storageMessage || message.hasPrefix("Server returned status 4")
    }

    private static func availableCapacity() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private func saveOptOut() {
        guard let ownerId else { return }
        UserDefaults.standard.set(Array(optedOut), forKey: "downloads.optOut.\(ownerId)")
    }

    /// Puts a transiently failed transfer back in the queue after a backoff (5 s, 30 s, 2 min, 5 min).
    private func scheduleRetry(_ id: String, receipt: TransferReceipt) {
        let count = (transientRetries[id] ?? 0) + 1
        transientRetries[id] = count
        TransferReceiptStore.remove(receipt, under: directory)
        statuses[id] = DownloadStatus(state: .queued, progress: 0, bytes: 0,
                                      errorMessage: "Retrying after a connection problem")
        retryWaiting.insert(id)
        PlaybackLog.logger.info("Download \(id) failed transiently (code \(receipt.errorCode ?? 0)); retry \(count)")
        let delay = [5, 30, 120, 300][min(count - 1, 3)]
        let attempt = receipt.attemptId
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self, self.attempts[id] == attempt, self.retryWaiting.contains(id) else { return }
            self.flushRetryWaiting(only: id)
        }
        startQueued()
    }

    private func flushRetryWaiting(only id: String? = nil) {
        let ids = id.map { [$0] } ?? Array(retryWaiting)
        for id in ids {
            retryWaiting.remove(id)
            guard statuses[id]?.state == .queued, active[id] == nil, !pending.contains(id) else { continue }
            pending.append(id)
        }
        if !ids.isEmpty { startQueued() }
    }

    /// Drops everything an account owned: running transfers, files, receipts and staged data.
    func purge(ownerId: String) {
        if self.ownerId == ownerId { deactivate() }
        let root = directory
        Task {
            for task in await session.allTasks where DownloadSessionDelegate.parse(task.taskDescription)?.ownerId == ownerId {
                task.cancel()
            }
            // Cancelled tasks still write a receipt on the delegate queue; let those land first.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await Task.detached(priority: .utility) {
                let fm = FileManager.default
                do { try fm.removeItem(at: root.appendingPathComponent(ownerId, isDirectory: true)) }
                catch let error as NSError where error.code != NSFileNoSuchFileError {
                    PlaybackLog.logger.error("Removing downloads of a removed account failed: \(error.localizedDescription)")
                } catch {}
                try? fm.removeItem(at: root.appendingPathComponent(".receipts", isDirectory: true)
                    .appendingPathComponent(ownerId, isDirectory: true))
            }.value
            UserDefaults.standard.removeObject(forKey: "downloads.optOut.\(ownerId)")
        }
    }

    /// Launch sweep: account folders whose account no longer exists (removed before this fix, or by a crash).
    func sweepOrphanedOwners(keeping accountIds: [UUID]) {
        let keep = Set(accountIds.map(\.uuidString))
        let root = directory
        Task {
            let orphans = await Task.detached(priority: .utility) { () -> [String] in
                let fm = FileManager.default
                var names = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                names.formUnion((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(".receipts").path)) ?? [])
                return names.filter { UUID(uuidString: $0) != nil && !keep.contains($0.uppercased()) && !keep.contains($0) }
            }.value
            for owner in orphans { self.purge(ownerId: owner) }
        }
    }

    // MARK: Persistence

    private func persist(_ id: String) {
        guard let database, let status = statuses[id], let attempt = attempts[id] else { return }
        let record = DownloadRecord(songId: id, state: status.state.rawValue, progress: status.progress,
                                    bytes: status.bytes, relativePath: paths[id],
                                    addedAt: addedAt[id] ?? Date(), errorMessage: status.errorMessage,
                                    attemptId: attempts[id], requestedBitRate: requestSnapshots[id]?.bitRate,
                                    requestedFormat: requestSnapshots[id]?.format,
                                    allowsCellular: requestSnapshots[id]?.allowsCellular)
        let previous = persistenceTail
        let operation = Task {
            await previous?.value
            do {
                try await database.write { db in
                    try db.execute(sql: """
                        UPDATE download SET state = ?, progress = ?, bytes = ?, relativePath = ?, addedAt = ?,
                            errorMessage = ?, requestedBitRate = ?, requestedFormat = ?, allowsCellular = ?
                        WHERE songId = ? AND attemptId = ?
                        """, arguments: [record.state, record.progress, record.bytes, record.relativePath,
                                        record.addedAt, record.errorMessage, record.requestedBitRate,
                                        record.requestedFormat, record.allowsCellular, id, attempt])
                }
            } catch {
                PlaybackLog.logger.error("Persisting download failed: \(error.localizedDescription)")
            }
        }
        persistenceTail = Task { await operation.value }
    }

    private func deleteRows(_ ids: Set<String>, attempts: [String: String], legacyPaths: [String: String], database: DatabaseWriter) {
        let previous = persistenceTail
        let operation = Task {
            await previous?.value
            do {
                try await database.write { db in
                    for id in ids {
                        guard let attempt = attempts[id] else { continue }
                        try db.execute(sql: "DELETE FROM download WHERE songId = ? AND attemptId = ?",
                                       arguments: [id, attempt])
                    }
                    for (id, path) in legacyPaths {
                        try db.execute(sql: "DELETE FROM download WHERE songId = ? AND attemptId IS NULL AND relativePath IS ?",
                                       arguments: [id, path])
                    }
                }
            } catch {
                PlaybackLog.logger.error("Deleting download rows failed: \(error.localizedDescription)")
            }
        }
        persistenceTail = Task { await operation.value }
    }
}
