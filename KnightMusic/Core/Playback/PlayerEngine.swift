import AVFoundation
import Foundation
import GRDB
import MediaPlayer
import UIKit

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
}

/// One slot of the play order. Stable identity so duplicates of the same song behave in lists.
struct QueueEntry: Identifiable, Hashable {
    let id: UUID
    let song: Song
    init(song: Song) {
        id = UUID()
        self.song = song
    }
}

struct ResolvedSource {
    var url: URL
    var kind: AudioSource
    var quality: StreamQuality?
    var description: String
}

/// An AVPlayerItem prepared for one queue entry, plus the observers watching it.
@MainActor
final class PreparedItem {
    let item: AVPlayerItem
    let entry: QueueEntry
    let resolved: ResolvedSource
    var observations: [NSKeyValueObservation] = []
    var isRadio: Bool { resolved.kind == .radio }

    init(item: AVPlayerItem, entry: QueueEntry, resolved: ResolvedSource) {
        self.item = item
        self.entry = entry
        self.resolved = resolved
    }
}

/// Gapless AVQueuePlayer engine. The logical queue lives in `order`; the player always holds at most
/// [current, next] so the next song is prepared ahead of time.
@MainActor @Observable
final class PlayerEngine {
    // MARK: Published state

    var currentSong: Song?
    var isPlaying = false
    var isBuffering = false
    /// Updated ~4 Hz; during scrubbing/seeking it reflects the requested position.
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var bufferedFraction: Double = 0
    /// Full play order (history + current + upcoming). `currentIndex` indexes into it.
    var order: [QueueEntry] = []
    var currentIndex = 0
    var repeatMode: RepeatMode = .off
    var shuffleEnabled = false
    var source: AudioSource = .streaming
    var formatDescription = ""
    var lastError: String?
    var currentRadio: RadioStation?
    var isScrubbing = false
    var serverQueueAvailable = false
    var serverQueuePreview: ServerPlayQueue?
    private var _volume: Float = 1

    var volume: Float {
        get { _volume }
        set {
            _volume = min(max(newValue, 0), 1)
            applyVolume()
        }
    }

    // MARK: Derived

    var upcoming: [QueueEntry] {
        guard currentIndex + 1 < order.count else { return [] }
        return Array(order[(currentIndex + 1)...])
    }
    var queue: [Song] { upcoming.map(\.song) }
    var history: [Song] {
        guard currentIndex > 0, currentIndex <= order.count else { return [] }
        return order[..<currentIndex].map(\.song)
    }
    var hasNext: Bool { nextExplicitIndex() != nil }
    var currentEntry: QueueEntry? { order.indices.contains(currentIndex) ? order[currentIndex] : nil }

    // MARK: Collaborators

    let streamCache = StreamCache()
    let scrobbler = Scrobbler()
    let sleepTimer = SleepTimer()

    @ObservationIgnored var services = PlaybackServices()
    @ObservationIgnored weak var downloads: DownloadManager?
    @ObservationIgnored let nowPlaying = NowPlayingCenter()
    @ObservationIgnored let audioSession = AudioSessionController()
    @ObservationIgnored var remote: RemoteCommands?
    @ObservationIgnored let queueStore = PlayQueueStore()
    @ObservationIgnored var onStarChanged: ((_ songId: String, _ starred: Bool) -> Void)?

    // MARK: Internals (internal access: used by extensions in other files)

    @ObservationIgnored var player = AVQueuePlayer()
    @ObservationIgnored var tracked: PreparedItem?
    @ObservationIgnored var nextPrepared: PreparedItem?
    @ObservationIgnored var originalOrder: [QueueEntry] = []
    @ObservationIgnored var userWantsPlaying = false
    @ObservationIgnored var failedEntryIds: Set<UUID> = []
    @ObservationIgnored var consecutiveFailures = 0
    @ObservationIgnored var retriedFromStream: Set<UUID> = []
    @ObservationIgnored var scrobbleBegun = false
    @ObservationIgnored var sleepFade: Float = 1
    @ObservationIgnored var endOfSongArmed = false
    @ObservationIgnored var seekGeneration = 0
    @ObservationIgnored var seekTarget: TimeInterval?
    @ObservationIgnored var lastTickUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored var lastPositionSave: TimeInterval = 0
    @ObservationIgnored var queueSaveTask: Task<Void, Never>?
    @ObservationIgnored var serverSaveTask: Task<Void, Never>?
    @ObservationIgnored var timeObserver: Any?
    @ObservationIgnored var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored var localSavedAt: Date?

    var settings: PlaybackSettings { services.settings }

    init() {
        sleepTimer.player = self
        installPlayerObservers()
        installItemNotifications()
        wireAudioSession()
        remote = RemoteCommands(engine: self)
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidEnterBackground() }
        })
    }

    /// Wire collaborators and restore the saved queue (paused). Call once at launch after the database is ready.
    func configure(services: PlaybackServices, downloads: DownloadManager, database: DatabaseWriter) {
        self.services = services
        self.downloads = downloads
        nowPlaying.artwork = services.artwork
        streamCache.configure(database: database)
        scrobbler.configure(services: services, database: database)
        applyVolume()
        restoreSavedQueue()
        Task { await checkServerQueue() }
    }

    /// Call when `services.artwork` / `services.urls` / `services.server` were replaced.
    func servicesDidChange() {
        nowPlaying.artwork = services.artwork
        if !services.isOffline { scrobbler.flushPending() }
    }

    /// Call when settings changed (ReplayGain, gapless, quality...).
    func settingsDidChange() {
        applyVolume()
        if tracked != nil { prepareNext() }
    }

    /// Call when connectivity changed: re-prepares the next item and flushes pending scrobbles.
    func networkDidChange() {
        if let next = nextPrepared, services.isOffline, next.resolved.kind == .streaming {
            prepareNext()
        } else if nextPrepared == nil, tracked != nil {
            prepareNext()
        }
        if !services.isOffline {
            scrobbler.flushPending()
            syncCache()
        }
    }

    // MARK: Transport

    func play(_ songs: [Song], startAt: Int? = nil, shuffle: Bool = false) {
        guard !songs.isEmpty else { return }
        let entries = songs.map(QueueEntry.init)
        currentRadio = nil
        failedEntryIds = []
        retriedFromStream = []
        consecutiveFailures = 0
        shuffleEnabled = shuffle
        let start = min(max(startAt ?? (shuffle ? Int.random(in: 0..<entries.count) : 0), 0), entries.count - 1)
        originalOrder = entries
        if shuffle {
            var rest = entries
            let first = rest.remove(at: start)
            order = [first] + rest.shuffled()
            currentIndex = 0
        } else {
            order = entries
            currentIndex = start
        }
        userWantsPlaying = true
        audioSession.activate()
        load(index: currentIndex, autoplay: true)
        saveQueueNow()
    }

    func playRadio(_ station: RadioStation) {
        guard let url = URL(string: station.streamUrl) else {
            report("Invalid radio stream address for \(station.name).")
            return
        }
        if services.isOffline {
            report("Radio isn't available offline.")
            return
        }
        let song = Song(id: "radio:\(station.id)", title: station.name, artist: "Live Radio")
        let entry = QueueEntry(song: song)
        currentRadio = station
        order = [entry]
        originalOrder = [entry]
        currentIndex = 0
        shuffleEnabled = false
        userWantsPlaying = true
        audioSession.activate()
        let resolved = ResolvedSource(url: url, kind: .radio, quality: nil, description: "Live Radio")
        activate(entry: entry, resolved: resolved, autoplay: true, startAt: 0)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        userWantsPlaying = false
        player.pause()
        isPlaying = false
        isBuffering = false
        nowPlaying.updatePlayback(elapsed: elapsedNow(), rate: 0)
        savePositionNow()
        scheduleServerSave(immediate: false)
    }

    func resume() {
        guard !order.isEmpty else { return }
        userWantsPlaying = true
        audioSession.activate()
        if tracked == nil {
            load(index: currentIndex, autoplay: true, startAt: currentTime)
            return
        }
        player.play()
        isPlaying = true
        nowPlaying.updatePlayback(elapsed: elapsedNow(), rate: 1)
    }

    func next() {
        guard !order.isEmpty, currentRadio == nil else { return }
        guard let target = nextExplicitIndex() else {
            finishQueue()
            return
        }
        userWantsPlaying = true
        audioSession.activate()
        // Fast path: the gapless next item is already prepared.
        if repeatMode != .one, let prepared = nextPrepared, order.indices.contains(target),
           order[target].id == prepared.entry.id {
            player.advanceToNextItem()
            player.play()
            isPlaying = true
            currentTime = 0
            promoteNext()
            return
        }
        load(index: target, autoplay: true)
    }

    func previous() {
        guard !order.isEmpty, currentRadio == nil else { return }
        if currentTime > 3 || (currentIndex == 0 && repeatMode != .all) {
            seek(to: 0)
            return
        }
        let target = currentIndex > 0 ? currentIndex - 1 : order.count - 1
        userWantsPlaying = true
        audioSession.activate()
        load(index: target, autoplay: true, scanBackward: true)
    }

    // MARK: Seeking

    func seek(to time: TimeInterval) {
        guard let tracked, !tracked.isRadio else { return }
        let target = max(0, duration > 0 ? min(time, duration) : time)
        seekGeneration += 1
        let generation = seekGeneration
        seekTarget = target
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seekTarget = nil
                if finished { self.nowPlaying.updatePlayback(elapsed: self.currentTime, rate: self.isPlaying ? 1 : 0) }
            }
        }
    }

    /// Scrubbing API for sliders: ticks stop overwriting `currentTime` until `endScrubbing`.
    func beginScrubbing() { isScrubbing = true }
    func scrub(to time: TimeInterval) { currentTime = max(0, duration > 0 ? min(time, duration) : time) }
    func endScrubbing(at time: TimeInterval) {
        isScrubbing = false
        seek(to: time)
    }

    // MARK: Repeat / star

    func cycleRepeat() {
        switch repeatMode {
        case .off: setRepeat(.all)
        case .all: setRepeat(.one)
        case .one: setRepeat(.off)
        }
    }

    func setRepeat(_ mode: RepeatMode) {
        guard repeatMode != mode else { return }
        repeatMode = mode
        prepareNext()
        remote?.refresh()
        saveQueueSoon()
    }

    func toggleStarCurrent() {
        guard let song = currentSong, currentRadio == nil, let server = services.server else { return }
        let starred = song.starred == nil
        updateCurrentSong { $0.starred = starred ? Date() : nil }
        onStarChanged?(song.id, starred)
        Task {
            do {
                try await server.setStarred(songId: song.id, starred: starred)
            } catch {
                PlaybackLog.logger.error("Star failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.updateCurrentSong { $0.starred = starred ? nil : Date() }
                    self.onStarChanged?(song.id, !starred)
                    self.report("Couldn't update favorite: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Reflect an external star change (e.g. from a list) in the current song / lock screen.
    func songStarChanged(songId: String, starred: Bool) {
        guard currentSong?.id == songId, (currentSong?.starred != nil) != starred else { return }
        updateCurrentSong { $0.starred = starred ? Date() : nil }
    }

    private func updateCurrentSong(_ change: (inout Song) -> Void) {
        guard var song = currentSong else { return }
        change(&song)
        currentSong = song
        remote?.refresh()
    }

    // MARK: Sleep timer hooks

    func setSleepFade(_ factor: Float) {
        sleepFade = min(max(factor, 0), 1)
        applyVolume()
    }

    func armEndOfSongPause(_ armed: Bool) {
        endOfSongArmed = armed
        if tracked != nil { prepareNext() }
    }

    // MARK: Volume / ReplayGain

    func applyVolume() {
        let gain = currentSong.map { replayGainFactor(for: $0) } ?? 1
        player.volume = _volume * gain * sleepFade
    }

    private func replayGainFactor(for song: Song) -> Float {
        let mode = settings.replayGain
        guard mode != .off, currentRadio == nil, let rg = song.replayGain else { return 1 }
        let gain: Double?
        let peak: Double?
        switch mode {
        case .album:
            gain = rg.albumGain ?? rg.trackGain
            peak = rg.albumGain != nil ? rg.albumPeak : rg.trackPeak
        case .track:
            gain = rg.trackGain ?? rg.albumGain
            peak = rg.trackGain != nil ? rg.trackPeak : rg.albumPeak
        case .off:
            return 1
        }
        guard let gain else { return 1 }
        var linear = pow(10, gain / 20)
        if let peak, peak > 0 { linear = min(linear, 1 / peak) }
        // AVPlayer can't amplify beyond unity; clamp to a sane floor too.
        return Float(min(max(linear, 0.05), 1))
    }

    // MARK: Errors

    func report(_ message: String) {
        PlaybackLog.logger.error("\(message)")
        lastError = message
    }

    func clearError() { lastError = nil }

    // MARK: Elapsed helper

    func elapsedNow() -> TimeInterval {
        let t = player.currentTime().seconds
        return t.isFinite && t >= 0 ? t : currentTime
    }
}
