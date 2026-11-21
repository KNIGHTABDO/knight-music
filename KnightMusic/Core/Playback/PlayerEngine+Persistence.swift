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
                savedQueueRevision = nil
                queueStore.save(nil as SavedQueue?, synchronous: true)
            }
            return
        }
        let signature = computeQueueSignature()
        if lastSavedQueueSignature != signature {
            lastSavedQueueSignature = signature
            let revision = UUID()
            savedQueueRevision = revision
            var originalPositions: [Int]?
            if shuffleEnabled {
                let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0) })
                originalPositions = originalOrder.compactMap { positions[$0.id] }
            }
            queueStore.save(SavedQueue(songs: order.map(\.song), originalOrder: originalPositions,
                                       repeatMode: repeatMode, shuffle: shuffleEnabled,
                                       revision: revision, entryIDs: order.map(\.id)),
                            synchronous: synchronous)
        }
        savePositionNow(synchronous: synchronous)
    }

    func savePositionNow(synchronous: Bool = false) {
        guard currentRadio == nil, !order.isEmpty else { return }
        if let song = currentSong { longTrackPositions.record(song, at: currentTime) }
        let now = Date()
        localSavedAt = now
        queueStore.save(SavedPosition(currentIndex: currentIndex, position: currentTime, savedAt: now,
                                      queueRevision: savedQueueRevision, entryID: currentEntry?.id),
                        synchronous: synchronous)
        lastPositionSave = ProcessInfo.processInfo.systemUptime
    }

    func restoreSavedQueue() {
        guard order.isEmpty, let saved = queueStore.loadQueue(), !saved.songs.isEmpty else {
            lastSavedQueueSignature = .empty
            return
        }
        let hasEntryIDs = saved.entryIDs.map { $0.count == saved.songs.count && Set($0).count == $0.count } ?? false
        let entries: [QueueEntry]
        if hasEntryIDs, let ids = saved.entryIDs {
            entries = zip(saved.songs, ids).map { QueueEntry(song: $0.0, id: $0.1) }
        } else {
            entries = saved.songs.map(QueueEntry.init)
        }
        order = entries
        originalOrder = saved.originalOrder.map { positions in
            positions.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        } ?? entries
        repeatMode = saved.repeatMode
        shuffleEnabled = saved.shuffle
        savedQueueRevision = hasEntryIDs ? saved.revision : nil
        lastSavedQueueSignature = savedQueueRevision == nil ? nil : computeQueueSignature()
        let position = queueStore.loadPosition()
        let matchingIndex = position.flatMap { saved.positionIndex($0) }
        let index = matchingIndex ?? 0
        let time = matchingIndex == nil ? 0 : max(0, position?.position ?? 0)
        localSavedAt = matchingIndex == nil ? nil : position?.savedAt
        currentIndex = index
        load(index: index, autoplay: false, startAt: time, silent: true)
    }

    // MARK: Server queue

    func checkServerQueue() async {
        guard settings.serverQueueSyncEnabled, !services.isOffline, let server = services.server else { return }
        let revision = queueEditRevision
        let endpoint = services.currentBaseURL?()
        let activation = AppModel.shared?.accountActivation
        do {
            guard let remoteQueue = try await server.getPlayQueue(), !remoteQueue.songs.isEmpty else { return }
            guard queueEditRevision == revision, services.currentBaseURL?() == endpoint,
                  AppModel.shared?.accountActivation == activation,
                  settings.serverQueueSyncEnabled else { return }
            let sameQueue = remoteQueue.songs.map(\.id) == serverQueueWindowIds()
            let localCurrentId = currentSong.flatMap { $0.isYouTube ? nil : $0.id }
            let sameCurrent = remoteQueue.currentSongId == localCurrentId
            if sameQueue && sameCurrent { return }
            let serverNewer: Bool
            if let changed = remoteQueue.changed {
                serverNewer = localSavedAt.map { changed > $0.addingTimeInterval(2) } ?? true
            } else {
                serverNewer = order.isEmpty
            }
            guard serverNewer, !isPlaying else { return }
            serverQueuePreview = remoteQueue
            serverQueuePreviewRevision = revision
            serverQueuePreviewEndpoint = endpoint
            serverQueuePreviewActivation = activation
            serverQueueAvailable = true
        } catch {
            PlaybackLog.logger.error("Fetching server play queue failed: \(error.localizedDescription)")
        }
    }

    /// Load the server's saved queue (paused at its saved position).
    func resumeServerQueue() {
        guard let remoteQueue = serverQueuePreview, !remoteQueue.songs.isEmpty else { return }
        // The toast lives a few seconds; don't replace something the user started meanwhile.
        guard !isPlaying, settings.serverQueueSyncEnabled, serverQueuePreviewRevision == queueEditRevision,
              serverQueuePreviewActivation == AppModel.shared?.accountActivation,
              serverQueuePreviewEndpoint == services.currentBaseURL?() else { dismissServerQueue(); return }
        let songs = remoteQueue.songs
        let possibleEntries = songs.indices.filter { songs[$0].id == remoteQueue.currentSongId }
        let start = possibleEntries.first ?? 0
        let position = possibleEntries.count == 1 ? TimeInterval(max(0, remoteQueue.positionMs)) / 1000 : 0
        let entries = songs.map(QueueEntry.init)
        endStation()
        currentRadio = nil
        failedEntryIds = []
        retriedFromStream = []
        consecutiveFailures = 0
        order = entries
        originalOrder = entries
        shuffleEnabled = false
        currentIndex = start
        dismissServerQueue()
        userWantsPlaying = false
        load(index: start, autoplay: false, startAt: position)
        if possibleEntries.count > 1 { playerNotice = "That song appears more than once in the saved queue. Choose where to resume." }
        saveQueueNow()
    }

    func dismissServerQueue() {
        serverQueueAvailable = false
        serverQueuePreview = nil
        serverQueuePreviewRevision = nil
        serverQueuePreviewEndpoint = nil
        serverQueuePreviewActivation = nil
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

    /// The slice of the queue that is uploaded to the server (and so what a remote copy of it contains).
    func serverQueueWindowIds() -> [String] {
        let windowStart = max(0, currentIndex - 20)
        guard windowStart < order.count else { return [] }
        // Same rule as the server upload: YouTube songs never exist on the server.
        return order[windowStart..<min(order.count, windowStart + 500)].map { $0.song.id }
            .filter { !$0.hasPrefix(Song.youTubePrefix) }
    }

    func pushServerQueue() async {
        guard settings.serverQueueSyncEnabled, !services.isOffline, let server = services.server,
              currentRadio == nil, !order.isEmpty else { return }
        let ids = serverQueueWindowIds()
        // A YouTube-only queue has nothing the server knows; an empty save would wipe the library queue
        // on every device.
        guard !ids.isEmpty else { return }
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
        var push: Task<Void, Never>?
        func endBackground() {
            guard background != .invalid else { return }
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        background = UIApplication.shared.beginBackgroundTask {
            push?.cancel()
            endBackground()
        }
        push = Task { [weak self] in
            await self?.pushServerQueue()
            endBackground()
        }
    }
}
