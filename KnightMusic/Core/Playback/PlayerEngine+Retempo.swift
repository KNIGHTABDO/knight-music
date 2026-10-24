import AVFoundation
import CoreMedia
import Foundation

/// One tempo change of the current deck without touching its rate: every AVPlayer rate change flushes the audio
/// output (an audible cut), so a twin of the same item is started at the new rate on the exact host time the
/// playing one reaches `at`, and the two cross over for a fraction of a second inside their audio taps.
@MainActor
final class RetempoJob {
    enum Purpose { case outgoing, incoming }

    let purpose: Purpose
    let old: AVQueuePlayer
    let source: PreparedItem
    let twin = AVQueuePlayer()
    let twinItem: PreparedItem
    let at: Double
    let rate: Float
    var hostStart: CMTime?
    var task: Task<Void, Never>?

    init(purpose: Purpose, old: AVQueuePlayer, source: PreparedItem, twinItem: PreparedItem, at: Double, rate: Float) {
        self.purpose = purpose
        self.old = old
        self.source = source
        self.twinItem = twinItem
        self.at = at
        self.rate = rate
    }
}

extension PlayerEngine {
    /// Same content on both decks, so a short linear crossover sums to a constant level.
    private var crossover: Double { 0.12 }

    /// Starts moving the current deck to `rate` at its media time `at`. False when that can't be done seamlessly
    /// (no audio tap: a stream, or the tap isn't attached yet).
    func startRetempo(_ purpose: RetempoJob.Purpose, at: Double, to rate: Float) -> Bool {
        guard retempoJob == nil, let source = tracked, source.tapAttached,
              source.resolved.kind == .downloaded || source.resolved.kind == .cached,
              let asset = source.item.asset as? AVURLAsset, player.rate > 0 else { return false }
        let twinItem = makePrepared(entry: source.entry, resolved: source.resolved, asset: asset, tap: false)
        twinItem.item.audioTimePitchAlgorithm = .spectral
        twinItem.automation.adopt(source.automation)
        twinItem.automation.setFade([[at, 0], [at + crossover * Double(rate), 1]])
        let job = RetempoJob(purpose: purpose, old: player, source: source, twinItem: twinItem, at: at, rate: rate)
        retempoJob = job
        job.task = Task { [weak self] in
            guard let self else { return }
            let started = await self.runRetempo(job)
            guard self.retempoJob === job else { return }
            if started {
                self.adoptTwin(job)
            } else {
                Log.playback.warning("Retempo: twin not ready in time")
                self.dropRetempo(job)
                self.retempoEnded(job, outcome: .failed)
            }
        }
        return true
    }

    /// Prepares the twin and starts it on the host clock; returns once the crossover is over.
    private func runRetempo(_ job: RetempoJob) async -> Bool {
        job.twinItem.tapRequested = true
        job.twinItem.tapAttached = await MixTap.attach(to: job.twinItem.item, automation: job.twinItem.automation)
        guard job.twinItem.tapAttached, retempoJob === job else { return false }
        let deck = job.twin
        deck.automaticallyWaitsToMinimizeStalling = false
        deck.actionAtItemEnd = .advance
        deck.defaultRate = job.rate
        deck.volume = job.old.volume
        deck.insert(job.twinItem.item, after: nil)
        for _ in 0..<150 where job.twinItem.item.status == .unknown {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard job.twinItem.item.status == .readyToPlay, retempoJob === job else { return false }
        let at = CMTime(seconds: job.at, preferredTimescale: 600_000)
        guard await deck.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero), retempoJob === job else { return false }
        _ = await deck.preroll(atRate: job.rate)
        guard retempoJob === job, job.old === player, job.old.rate > 0, let timebase = job.source.item.timebase else {
            return false
        }
        let clock = CMClockGetHostTimeClock()
        let hostStart = CMSyncConvertTime(at, from: timebase, to: clock)
        let lead = (hostStart - CMClockGetTime(clock)).seconds
        guard hostStart.isValid, lead > 0.05 else { return false }
        job.source.automation.setFade([[job.at, 1], [job.at + crossover * Double(job.old.rate), 0]])
        deck.setRate(job.rate, time: at, atHostTime: hostStart)
        job.hostStart = hostStart
        Log.playback.info("Retempo to \(String(format: "%.4f", job.rate)) in \(String(format: "%.2f", lead))s")
        try? await Task.sleep(for: .seconds(lead + crossover + 0.15))
        return true
    }

    /// The twin becomes the current deck; the old one, silent now, is dropped.
    private func adoptTwin(_ job: RetempoJob) {
        retempoJob = nil
        let old = job.old
        let queued = old.items().filter { $0 !== job.source.item }
        uninstallPlayerObservers()
        queued.forEach { old.remove($0) }
        player = job.twin
        for item in queued where player.canInsert(item, after: nil) { player.insert(item, after: nil) }
        installPlayerObservers()
        player.automaticallyWaitsToMinimizeStalling = false
        player.defaultRate = job.rate
        old.pause()
        old.removeAllItems()
        job.source.observations.removeAll()
        job.source.automation.clear()
        job.twinItem.automation.clearFade()
        if tracked === job.source { tracked = job.twinItem }
        if let session = mixSession, session.outgoing === job.source { session.outgoing = job.twinItem }
        nowPlaying.updatePlayback(elapsed: elapsedNow(), rate: Double(job.rate))
        retempoEnded(job, outcome: .done)
    }

    private func dropRetempo(_ job: RetempoJob) {
        retempoJob = nil
        job.task?.cancel()
        job.twin.pause()
        job.twin.removeAllItems()
        job.twinItem.observations.removeAll()
        job.twinItem.automation.clear()
        job.source.automation.clearFade()
    }

    /// Finishes a retempo at once before a user action (pause, seek, skip): the twin takes over if it already
    /// sounds, otherwise it's dropped and the change is tried again later.
    func settleRetempo() {
        guard let job = retempoJob else { return }
        job.task?.cancel()
        if let hostStart = job.hostStart, CMClockGetTime(CMClockGetHostTimeClock()) >= hostStart {
            adoptTwin(job)
        } else {
            dropRetempo(job)
            retempoEnded(job, outcome: .pending)
        }
    }

    /// Last resort when no twin could take over (heard as a short cut).
    func setRateAbruptly(_ rate: Float) {
        player.defaultRate = rate
        guard player.rate > 0, abs(player.rate - rate) > 0.0001 else { return }
        player.rate = rate
        nowPlaying.updatePlayback(elapsed: elapsedNow(), rate: Double(rate))
    }
}
