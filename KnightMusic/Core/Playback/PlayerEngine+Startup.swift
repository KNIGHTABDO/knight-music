import AVFoundation
import Foundation

// Fast starts for streamed songs. AVPlayer's own start rule (`automaticallyWaitsToMinimizeStalling`) waits
// until it predicts the whole song can play through, which on a slow link or a lossless original can take
// many seconds even though plenty of audio is already buffered. Once a few seconds are in hand the start is
// nudged with `playImmediately`; if the link really cannot keep up AVPlayer stalls and recovers by itself.
extension PlayerEngine {
    /// Seconds buffered past the playhead before a first start (or a start after a seek) is forced.
    private static let quickStartAhead: Double = 2
    /// After a mid-song stall more must be in hand, so a slow link does not play/stall/play in quick succession.
    private static let stallRecoveryAhead: Double = 8
    private static let maxKicksPerStart = 3

    /// Background save-ahead downloads wait while a streamed song starts, so it gets the whole connection.
    func holdBackgroundCaching(for p: PreparedItem) {
        guard p.resolved.kind == .streaming else { return }
        streamCache.holdBackground(seconds: 4)
    }

    /// The tracked song is audibly playing.
    func startupFinished(_ p: PreparedItem) {
        p.quickStart = false
        if let requested = p.startRequestedAt {
            p.startRequestedAt = nil
            let ms = Int((ProcessInfo.processInfo.systemUptime - requested) * 1000)
            PlaybackLog.logger.info("Start: \(ms, privacy: .public) ms to sound (\(String(describing: p.resolved.kind), privacy: .public), kicks \(p.kicks, privacy: .public))")
        }
        guard !p.startedOnce else { return }
        p.startedOnce = true
        streamCache.releaseHold()
        prefetchUpcomingYouTube()
    }

    func kickStartIfBuffered(_ p: PreparedItem) {
        guard p === tracked, p.resolved.kind == .streaming, userWantsPlaying, !isInterrupted, seekTarget == nil,
              p.kicks < Self.maxKicksPerStart, player.currentItem === p.item, p.item.status == .readyToPlay,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              // AutoMix and retempo drive their own decks and rates; never interfere with a blend.
              mixTail == nil, retempoJob == nil, mixSession.map({ $0.phase == .planned }) ?? true else { return }
        let reason = player.reasonForWaitingToPlay
        guard reason == .evaluatingBufferingRate || reason == .toMinimizeStalls else { return }
        let now = p.item.currentTime().seconds
        guard now.isFinite else { return }
        let ranges = p.item.loadedTimeRanges.map(\.timeRangeValue)
        guard let range = ranges.first(where: { now >= $0.start.seconds - 0.25 && now < ($0.start + $0.duration).seconds }) else { return }
        let ahead = (range.start + range.duration).seconds - now
        let remaining = p.item.duration.seconds - now
        let needed = p.quickStart ? Self.quickStartAhead : Self.stallRecoveryAhead
        // Near the end of the song whatever is left counts as enough.
        guard ahead >= needed || (remaining.isFinite && remaining > 0 && ahead >= remaining - 0.25) else { return }
        p.kicks += 1
        let rate = player.defaultRate > 0 ? player.defaultRate : 1
        PlaybackLog.logger.info("Start: playing with \(ahead, format: .fixed(precision: 1), privacy: .public) s buffered (\(reason?.rawValue ?? "-", privacy: .public))")
        player.playImmediately(atRate: rate)
    }

    /// Resolve the next YouTube songs (stream URL plus their first bytes) while this one plays, so skipping to
    /// them starts at once instead of waiting on YouTube's player API.
    func prefetchUpcomingYouTube() {
        guard !services.isOffline, currentRadio == nil, currentIndex < order.count else { return }
        let ids = order.dropFirst(currentIndex + 1).prefix(2).compactMap { $0.song.youTubeVideoId }
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) {
            for id in ids { await YouTubeMusic.shared.prefetch(videoId: id) }
        }
    }
}
