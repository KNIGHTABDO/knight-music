import Foundation
import UIKit

// Local queue persistence + server play-queue sync.
extension PlayerEngine {
    func saveQueueSoon() {
        queueSaveTask?.cancel()
        queueSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveQueueNow()
        }
        scheduleServerSave()
    }

    func computeQueueSignature() -> QueueSignature {
        guard !order.isEmpty else { return .empty }
        var orderHasher = Hasher()
        for entry in order {
            orderHasher.combine(entry.id)
        }
        var origHasher = Hasher()
        for entry in originalOrder {
            origHasher.combine(entry.id)
        }
        return QueueSignature(
            count: order.count,
            orderHash: orderHasher.finalize(),
            originalOrderHash: origHasher.finalize(),
            repeatMode: repeatMode,
            shuffle: shuffleEnabled
        )
    }

    func saveQueueNow(synchronous: Bool = false) {
        guard currentRadio == nil else { return }
        guard !order.isEmpty else {
            let signature = QueueSignature.empty
            if lastSavedQueueSignature != signature {
                lastSavedQueueSignature = signature
                queueStore.save(nil as SavedQueue?, synchronous: true)
            }
            return
        }
        let signature = computeQueueSignature()
        if lastSavedQueueSignature != signature {
            lastSavedQueueSignature = signature
            var originalPositions: [Int]?
            if shuffleEnabled {
                let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0) })
                originalPositions = originalOrder.compactMap { positions[$0.id] }
            }
            queueStore.save(SavedQueue(songs: order.map(\.song), originalOrder: originalPositions,
                                       repeatMode: repeatMode, shuffle: shuffleEnabled),
                            synchronous: synchronous)
        }
        savePositionNow(synchronous: synchronous)
    }

    func savePositionNow(synchronous: Bool = false) {
        guard currentRadio == nil, !order.isEmpty else { return }
        let now = Date()
        localSavedAt = now
        queueStore.save(SavedPosition(currentIndex: currentIndex, position: currentTime, savedAt: now),
                        synchronous: synchronous)
        lastPositionSave = ProcessInfo.processInfo.systemUptime
    }

    func restoreSavedQueue() {
        guard order.isEmpty, let saved = queueStore.loadQueue(), !saved.songs.isEmpty else {
            lastSavedQueueSignature = .empty
            return
        }
        let entries = saved.songs.map(QueueEntry.init)
        order = entries
        originalOrder = saved.originalOrder.map { positions in
            positions.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        } ?? entries
        repeatMode = saved.repeatMode
        shuffleEnabled = saved.shuffle
        lastSavedQueueSignature = computeQueueSignature()
        let position = queueStore.loadPosition()
        localSavedAt = position?.savedAt
        let index = min(max(position?.currentIndex ?? 0, 0), entries.count - 1)
        currentIndex = index
        load(index: index, autoplay: false, startAt: position?.position ?? 0, silent: true)
    }

    // MARK: Server queue

    func checkServerQueue() async {
        guard settings.serverQueueSyncEnabled, !services.isOffline, let server = services.server else { return }
        do {
            guard let remoteQueue = try await server.getPlayQueue(), !remoteQueue.songs.isEmpty else { return }
            let sameQueue = remoteQueue.songs.map(\.id) == order.map { $0.song.id }
            let sameCurrent = remoteQueue.currentSongId == currentSong?.id
            if sameQueue && sameCurrent { return }
            let serverNewer: Bool
            if let changed = remoteQueue.changed {
                serverNewer = localSavedAt.map { changed > $0.addingTimeInterval(2) } ?? true
            } else {
                serverNewer = order.isEmpty
            }
            guard serverNewer, !isPlaying else { return }
            serverQueuePreview = remoteQueue
            serverQueueAvailable = true
        } catch {
            PlaybackLog.logger.error("Fetching server play queue failed: \(error.localizedDescription)")
        }
    }

    /// Load the server's saved queue (paused at its saved position).
    func resumeServerQueue() {
        guard let remoteQueue = serverQueuePreview, !remoteQueue.songs.isEmpty else { return }
        let songs = remoteQueue.songs
        let start = remoteQueue.currentSongId.flatMap { id in songs.firstIndex { $0.id == id } } ?? 0
        let entries = songs.map(QueueEntry.init)
        currentRadio = nil
        failedEntryIds = []
        order = entries
        originalOrder = entries
        shuffleEnabled = false
        currentIndex = start
        dismissServerQueue()
        userWantsPlaying = false
        load(index: start, autoplay: false, startAt: TimeInterval(remoteQueue.positionMs) / 1000)
        saveQueueNow()
    }

    func dismissServerQueue() {
        serverQueueAvailable = false
        serverQueuePreview = nil
    }

    func scheduleServerSave(immediate: Bool = false) {
        guard settings.serverQueueSyncEnabled, services.server != nil, currentRadio == nil else { return }
        serverSaveTask?.cancel()
        serverSaveTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .seconds(5)) }
            guard !Task.isCancelled else { return }
            await self?.pushServerQueue()
        }
    }

    func pushServerQueue() async {
        guard settings.serverQueueSyncEnabled, !services.isOffline, let server = services.server,
              currentRadio == nil, !order.isEmpty else { return }
        let windowStart = max(0, currentIndex - 20)
        let ids = order[windowStart..<min(order.count, windowStart + 500)].map { $0.song.id }
        do {
            try await server.savePlayQueue(songIds: ids, currentSongId: currentSong?.id,
                                           positionMs: Int(currentTime * 1000))
        } catch {
            PlaybackLog.logger.error("Saving play queue to server failed: \(error.localizedDescription)")
        }
    }

    func appDidEnterBackground() {
        saveQueueNow(synchronous: true)
        guard settings.serverQueueSyncEnabled, services.server != nil else { return }
        serverSaveTask?.cancel()
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(background)
        }
        Task { [weak self] in
            await self?.pushServerQueue()
            UIApplication.shared.endBackgroundTask(background)
        }
    }
}
