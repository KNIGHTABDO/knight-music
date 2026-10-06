import AVFoundation
import Foundation
import MediaPlayer
import UIKit

// Loading items, gapless preparation, player observation and failure handling.
extension PlayerEngine {
    // MARK: Source resolution

    func currentQuality() -> StreamQuality {
        let s = settings
        let rate = services.network == .cellular ? s.cellularMaxBitRate : s.wifiMaxBitRate
        return rate > 0 ? StreamQuality(maxBitRate: rate, format: s.transcodeFormat ?? "mp3") : .original
    }

    func cacheExtension(for song: Song, quality: StreamQuality) -> String {
        if quality.maxBitRate != nil { return quality.format ?? "mp3" }
        return song.suffix ?? "mp3"
    }

    /// Side-effect free availability check (no cache LRU touch).
    func isPlayable(_ song: Song) -> Bool {
        if downloads?.localFileURL(for: song.id) != nil { return true }
        if streamCache.contains(song.id) { return true }
        return !services.isOffline && services.urls != nil
    }

    func streamURL(for song: Song, quality: StreamQuality) -> URL? {
        services.urls?.streamURL(songId: song.id, maxBitRate: quality.maxBitRate,
                                 format: quality.format ?? (quality.maxBitRate == nil ? "raw" : nil),
                                 timeOffset: nil)
    }

    func resolve(_ song: Song) -> ResolvedSource? {
        if let url = downloads?.localFileURL(for: song.id) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            return ResolvedSource(url: url, kind: .downloaded, quality: nil,
                                  description: AudioDescription.make(kind: .downloaded, song: song, quality: nil,
                                                                     fileExtension: url.pathExtension, fileBytes: bytes))
        }
        if let url = streamCache.cachedFileURL(for: song.id) {
            let q = streamCache.quality(for: song.id)
            return ResolvedSource(url: url, kind: .cached, quality: q,
                                  description: AudioDescription.make(kind: .cached, song: song, quality: q))
        }
        guard !services.isOffline else { return nil }
        let q = currentQuality()
        guard let url = streamURL(for: song, quality: q) else { return nil }
        return ResolvedSource(url: url, kind: .streaming, quality: q,
                              description: AudioDescription.make(kind: .streaming, song: song, quality: q))
    }

    // MARK: Order navigation

    func nextExplicitIndex() -> Int? {
        guard !order.isEmpty else { return nil }
        func usable(_ i: Int) -> Bool {
            !failedEntryIds.contains(order[i].id) && isPlayable(order[i].song)
        }
        let cur = min(max(currentIndex, 0), order.count - 1)
        if cur + 1 < order.count {
            for i in (cur + 1)..<order.count where usable(i) { return i }
        }
        if repeatMode == .all {
            for i in 0...cur where usable(i) { return i }
        }
        return nil
    }

    func naturalNextIndex() -> Int? {
        if repeatMode == .one, let entry = currentEntry, !failedEntryIds.contains(entry.id) {
            return currentIndex
        }
        return nextExplicitIndex()
    }

    // MARK: Loading

    /// Make `index` (or the nearest playable entry) current. Returns false if nothing was playable.
    @discardableResult
    func load(index: Int, autoplay: Bool, startAt: TimeInterval = 0,
              scanBackward: Bool = false, silent: Bool = false) -> Bool {
        guard !order.isEmpty else {
            clearPlayback()
            return false
        }
        let start = min(max(index, 0), order.count - 1)
        var sequence: [Int]
        if scanBackward {
            sequence = Array((0...start).reversed())
            if repeatMode == .all, start + 1 < order.count { sequence += Array(((start + 1)..<order.count).reversed()) }
        } else {
            sequence = Array(start..<order.count)
            if repeatMode == .all, start > 0 { sequence += Array(0..<start) }
        }
        for i in sequence {
            let entry = order[i]
            if failedEntryIds.contains(entry.id) { continue }
            guard let resolved = resolve(entry.song) else { continue }
            currentIndex = i
            activate(entry: entry, resolved: resolved, autoplay: autoplay, startAt: i == index ? startAt : 0)
            return true
        }
        userWantsPlaying = false
        stopPlayer()
        if !silent {
            report(services.isOffline ? "None of the songs in the queue are available offline."
                                      : "Couldn't find a playable source for the queue.")
        }
        return false
    }

    func activate(entry: QueueEntry, resolved: ResolvedSource, autoplay: Bool, startAt: TimeInterval) {
        settleAutoMix(keepIncoming: false)
        scrobbler.end()
        seekGeneration += 1
        seekTarget = nil
        tracked?.observations.removeAll()
        nextPrepared?.observations.removeAll()
        nextPrepared = nil
        let prepared = makePrepared(entry: entry, resolved: resolved)
        tracked = prepared
        player.pause()
        player.removeAllItems()
        player.insert(prepared.item, after: nil)
        publishCurrent(prepared, startAt: startAt, playing: autoplay)
        if startAt > 0 { seek(to: startAt) }
        applyVolume()
        if autoplay {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
            isBuffering = false
        }
        prepareNext()
        syncCache()
        saveQueueSoon()
    }

    func publishCurrent(_ p: PreparedItem, startAt: TimeInterval, playing: Bool) {
        let song = p.entry.song
        currentSong = song
        source = p.resolved.kind
        formatDescription = p.resolved.description
        duration = p.isRadio ? 0 : song.durationSeconds
        currentTime = startAt
        bufferedFraction = (p.resolved.kind == .streaming || p.resolved.kind == .radio) ? 0 : 1
        scrobbleBegun = false
        if let i = order.firstIndex(where: { $0.id == p.entry.id }) { currentIndex = i }
        nowPlaying.setSong(song, isLive: p.isRadio, duration: duration, elapsed: startAt, rate: playing ? 1 : 0,
                           queueIndex: currentIndex, queueCount: order.count)
        remote?.refresh()
    }

    func stopPlayer() {
        settleAutoMix(keepIncoming: false)
        tracked?.observations.removeAll()
        nextPrepared?.observations.removeAll()
        tracked = nil
        nextPrepared = nil
        player.pause()
        player.removeAllItems()
        isPlaying = false
        isBuffering = false
    }

    func clearPlayback() {
        stopPlayer()
        scrobbler.end()
        order = []
        originalOrder = []
        currentIndex = 0
        currentSong = nil
        currentRadio = nil
        duration = 0
        currentTime = 0
        bufferedFraction = 0
        formatDescription = ""
        nowPlaying.clear()
        remote?.refresh()
        streamCache.retainOnly([])
        saveQueueNow()
    }

    /// Reached the end of the queue (repeat off): park on the first playable song, paused.
    func finishQueue() {
        scrobbler.end()
        userWantsPlaying = false
        failedEntryIds = []
        load(index: 0, autoplay: false, silent: true)
        nowPlaying.updatePlayback(elapsed: 0, rate: 0)
    }

    // MARK: Gapless preparation

    func makePrepared(entry: QueueEntry, resolved: ResolvedSource) -> PreparedItem {
        let item = AVPlayerItem(asset: AVURLAsset(url: resolved.url))
        let prepared = PreparedItem(item: item, entry: entry, resolved: resolved)
        if settings.autoMix { attachTap(prepared) }
        prepared.observations = [
            item.observe(\.status, options: [.new]) { [weak self, weak prepared] _, _ in
                Task { @MainActor in
                    guard let self, let prepared else { return }
                    self.itemStatusChanged(prepared)
                }
            },
            item.observe(\.duration, options: [.new]) { [weak self, weak prepared] _, _ in
                Task { @MainActor in
                    guard let self, let prepared else { return }
                    self.itemMetricsChanged(prepared)
                }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self, weak prepared] _, _ in
                Task { @MainActor in
                    guard let self, let prepared else { return }
                    self.itemMetricsChanged(prepared)
                }
            },
        ]
        return prepared
    }

    /// Ensure the player holds exactly [current, next-to-play], and plan an AutoMix transition into it.
    func prepareNext() {
        guard tracked != nil else { return }
        if let session = mixSession, session.phase != .planned {
            // A transition already under way keeps going as long as its song is still the one up next.
            if settings.autoMix, repeatMode != .one, !endOfSongArmed, let index = naturalNextIndex(),
               order.indices.contains(index), order[index].id == session.target.id { return }
            cancelMix(reprepare: false)
        }
        prepareGaplessNext()
        planAutoMix()
    }

    /// The gapless successor only (used when a planned transition is abandoned for this song).
    func prepareNextWithoutAutoMix() {
        autoMixPlanTask?.cancel()
        prepareGaplessNext()
    }

    func prepareGaplessNext() {
        guard let tracked else { return }
        for item in player.items() where item !== tracked.item { player.remove(item) }
        nextPrepared?.observations.removeAll()
        nextPrepared = nil
        guard settings.gapless, !endOfSongArmed, !tracked.isRadio,
              let index = naturalNextIndex(), let resolved = resolve(order[index].song) else { return }
        let prepared = makePrepared(entry: order[index], resolved: resolved)
        player.insert(prepared.item, after: tracked.item)
        nextPrepared = prepared
    }

    func promoteNext() {
        guard let next = nextPrepared else { return }
        scrobbler.end()
        tracked?.observations.removeAll()
        tracked = next
        nextPrepared = nil
        seekGeneration += 1
        seekTarget = nil
        publishCurrent(next, startAt: 0, playing: true)
        applyVolume()
        prepareNext()
        syncCache()
        saveQueueSoon()
    }

    func advanceAfterEnd() {
        guard tracked != nil else { return }
        cancelMix(reprepare: false)
        if endOfSongArmed {
            endOfSongArmed = false
            sleepTimer.endOfSongReached()
            userWantsPlaying = false
            if let i = nextExplicitIndex() {
                load(index: i, autoplay: false)
            } else {
                finishQueue()
            }
            return
        }
        if let i = naturalNextIndex() {
            load(index: i, autoplay: true)
        } else {
            finishQueue()
        }
    }

    // MARK: Cache feeding

    func syncCache() {
        guard settings.autoMix, settings.streamCacheEnabled, !services.isOffline, currentRadio == nil,
              services.urls != nil, currentIndex < order.count else {
            // AutoMix still needs its incoming song as a local file when the stream cache is off.
            // With AutoMix off nothing is saved ahead: pending background downloads are cancelled.
            let keep = plannedMix.map { Set([$0.to.id]) } ?? []
            if !settings.autoMix || !settings.streamCacheEnabled || currentRadio != nil { streamCache.retainOnly(keep) }
            return
        }
        let depth = services.network == .cellular ? 2 : 3
        let upper = min(order.count, currentIndex + depth)
        let songs = order[currentIndex..<upper].map(\.song)
        streamCache.retainOnly(Set(songs.map(\.id) + (plannedMix.map { [$0.to.id] } ?? [])))
        let quality = currentQuality()
        for song in songs where downloads?.localFileURL(for: song.id) == nil && !streamCache.contains(song.id) {
            guard let url = streamURL(for: song, quality: quality) else { continue }
            streamCache.cache(songId: song.id, url: url, quality: quality,
                              fileExtension: cacheExtension(for: song, quality: quality),
                              limitMB: settings.streamCacheLimitMB)
        }
    }

    // MARK: Observation

    func installPlayerObservers() {
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeTick(time) }
        }
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.timeControlChanged() }
            },
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.currentItemChanged() }
            },
        ]
    }

    func installItemNotifications() {
        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, let t = self.tracked, t.item === item, self.nextPrepared == nil else { return }
                self.advanceAfterEnd()
            }
        })
        notificationTokens.append(nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, let t = self.tracked, t.item === item else { return }
                self.handleFailure(t)
            }
        })
    }

    func wireAudioSession() {
        audioSession.onInterruptionEnded = { [weak self] shouldResume in
            guard let self, shouldResume, self.userWantsPlaying else { return }
            self.resume()
        }
        audioSession.onRouteLost = { [weak self] in self?.pause() }
        audioSession.onMediaServicesReset = { [weak self] in self?.recoverFromMediaServicesReset() }
    }

    func recoverFromMediaServicesReset() {
        let wasPlaying = userWantsPlaying
        let position = elapsedNow()
        let index = currentIndex
        settleAutoMix(keepIncoming: false)
        uninstallPlayerObservers()
        stopPlayer()
        player = AVQueuePlayer()
        spareDeck = AVQueuePlayer()
        installPlayerObservers()
        audioSession.activate()
        guard !order.isEmpty else { return }
        load(index: index, autoplay: wasPlaying, startAt: position)
    }

    func timeTick(_ time: CMTime) {
        autoMixTick()
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(max(now - lastTickUptime, 0), 1)
        lastTickUptime = now
        guard !isScrubbing, seekTarget == nil else { return }
        let t = time.seconds
        guard t.isFinite, t >= 0 else { return }
        currentTime = t
        guard isPlaying, !isBuffering else { return }
        if !scrobbleBegun, let song = currentSong, currentRadio == nil {
            scrobbleBegun = true
            scrobbler.begin(song)
        }
        scrobbler.addPlayed(delta)
        if now - lastPositionSave > 10 { savePositionNow() }
    }

    func timeControlChanged() {
        let status = player.timeControlStatus
        let playing = status != .paused
        if isPlaying != playing { isPlaying = playing }
        let buffering = status == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay != .noItemToPlay
        if isBuffering != buffering { isBuffering = buffering }
        nowPlaying.updatePlayback(elapsed: elapsedNow(), rate: status == .playing ? 1 : 0)
    }

    func currentItemChanged() {
        let live = player.currentItem
        if live === tracked?.item { return }
        if let live, let next = nextPrepared, live === next.item {
            promoteNext()
            return
        }
        if live == nil, tracked != nil { advanceAfterEnd() }
    }

    func itemStatusChanged(_ p: PreparedItem) {
        switch p.item.status {
        case .readyToPlay:
            if p === tracked {
                consecutiveFailures = 0
                itemMetricsChanged(p)
            }
        case .failed:
            handleFailure(p)
        default:
            break
        }
    }

    func itemMetricsChanged(_ p: PreparedItem) {
        guard p === tracked else { return }
        let d = p.item.duration.seconds
        if !p.isRadio, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            nowPlaying.updateDuration(d)
        }
        switch p.resolved.kind {
        case .downloaded, .cached:
            if bufferedFraction != 1 { bufferedFraction = 1 }
        case .streaming:
            guard duration > 0 else { return }
            let end = p.item.loadedTimeRanges.map { $0.timeRangeValue }
                .map { ($0.start + $0.duration).seconds }.filter { $0.isFinite }.max() ?? 0
            bufferedFraction = min(max(end / duration, 0), 1)
        case .radio:
            break
        }
    }

    // MARK: Failures

    func handleFailure(_ p: PreparedItem) {
        let message = p.item.error?.localizedDescription ?? "Unknown playback error"
        PlaybackLog.logger.error("Item failed (\(p.entry.song.id)): \(message)")
        if p === nextPrepared {
            if p.resolved.kind == .cached {
                streamCache.remove(songId: p.entry.song.id)
            } else {
                failedEntryIds.insert(p.entry.id)
            }
            prepareNext()
            return
        }
        guard p === tracked else { return }
        if p.resolved.kind == .cached, !retriedFromStream.contains(p.entry.id) {
            retriedFromStream.insert(p.entry.id)
            streamCache.remove(songId: p.entry.song.id)
            load(index: currentIndex, autoplay: userWantsPlaying, startAt: currentTime)
            return
        }
        failedEntryIds.insert(p.entry.id)
        report("Couldn\u{2019}t play \u{201C}\(p.entry.song.title)\u{201D}: \(message)")
        consecutiveFailures += 1
        if p.isRadio || consecutiveFailures >= min(max(order.count, 1), 5) {
            userWantsPlaying = false
            stopPlayer()
            return
        }
        if let i = nextExplicitIndex() {
            load(index: i, autoplay: userWantsPlaying)
        } else {
            userWantsPlaying = false
            stopPlayer()
        }
    }
}
