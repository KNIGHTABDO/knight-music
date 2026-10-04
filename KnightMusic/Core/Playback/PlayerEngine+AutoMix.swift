import AVFoundation
import CoreMedia
import Foundation

/// A transition being prepared or played: the incoming song on its own deck, started at an exact host time so
/// its beats land on the outgoing song's, then handed the "current song" role.
@MainActor
final class MixSession {
    enum Phase { case planned, preparing, ready, scheduled, mixing }

    let plan: AutoMixPlan
    let a: AutoMixPlan.Deck
    let b: AutoMixPlan.Deck
    let outgoing: PreparedItem
    let target: QueueEntry
    /// Chosen when preparation starts (the previous transition's deck may still be fading out at plan time).
    var deck: AVQueuePlayer?
    var phase: Phase = .planned
    var incoming: PreparedItem?
    var statusObservation: NSKeyValueObservation?
    var fetchedAt = ProcessInfo.processInfo.systemUptime

    var rate: Float { Float(b.rate ?? 1) }
    /// A's rate while B plays (1 unless the tempos meet halfway).
    var aRate: Float { Float(a.rate ?? 1) }
    var aRampIndex = 0

    init(plan: AutoMixPlan, a: AutoMixPlan.Deck, b: AutoMixPlan.Deck, outgoing: PreparedItem, target: QueueEntry) {
        self.plan = plan
        self.a = a
        self.b = b
        self.outgoing = outgoing
        self.target = target
    }
}

/// After the handoff: the previous song fading out on its old deck, and the new song easing back to its tempo.
@MainActor
final class MixTail {
    let player: AVQueuePlayer
    let prepared: PreparedItem
    let stopAt: Double
    let outgoingRate: Float
    /// The incoming song's media time after which its automation is flat (gain 1, filters open).
    let automationEnd: Double
    var ramp: [[Double]]
    var rampIndex = 0
    var finished = false

    init(player: AVQueuePlayer, prepared: PreparedItem, stopAt: Double, outgoingRate: Float, automationEnd: Double,
         ramp: [[Double]]) {
        self.player = player
        self.prepared = prepared
        self.stopAt = stopAt
        self.outgoingRate = outgoingRate
        self.automationEnd = automationEnd
        self.ramp = ramp
    }
}

extension PlayerEngine {
    /// How long before the transition the incoming deck starts loading and pre-rolling.
    private var prepareLead: Double { 16 }

    var isAutoMixing: Bool { autoMixActive }

    // MARK: Planning

    /// Fetch a plan for current → natural next. Called from `prepareNext`, so it follows every queue change.
    func planAutoMix() {
        if let session = mixSession, session.phase != .planned { return }
        mixSession = nil
        autoMixPlanTask?.cancel()
        plannedMix = nil
        autoMixNote = nil
        guard settings.autoMix, let tracked, !tracked.isRadio, currentRadio == nil else { return }
        guard repeatMode != .one, !endOfSongArmed else {
            autoMixNote = repeatMode == .one ? "Repeat One is on" : "Sleep timer ends after this song"
            return
        }
        guard !player.isExternalPlaybackActive else {
            autoMixNote = "AutoMix pauses while playing to AirPlay"
            return
        }
        guard let provider = services.autoMix else {
            autoMixNote = "Connect to your server to use AutoMix"
            return
        }
        guard let index = naturalNextIndex(), order.indices.contains(index), order[index].id != tracked.entry.id else {
            autoMixNote = "Nothing up next"
            return
        }
        let target = order[index]
        let fromId = tracked.entry.song.id, toId = target.song.id
        let trackedEntry = tracked.entry.id
        autoMixPlanTask = Task { [weak self] in
            let plan = await provider.plan(from: fromId, to: toId)
            guard !Task.isCancelled, let self else { return }
            self.installPlan(plan, trackedEntry: trackedEntry, target: target)
        }
        prefetchUpcomingPlans(provider)
    }

    /// The next ~20 transitions of the queue, fetched once in the background (they then mix offline too).
    private func prefetchUpcomingPlans(_ provider: AutoMixPlanProvider) {
        let upcoming = Array(order.dropFirst(currentIndex).prefix(21)).map(\.song.id)
        guard upcoming.count > 2 else { return }
        let pairs = zip(upcoming, upcoming.dropFirst()).filter { $0 != $1 }.map { (from: $0, to: $1) }
        let signature = pairs.map { "\($0.from)>\($0.to)" }.joined(separator: ",")
        guard signature != lastPrefetchSignature else { return }
        lastPrefetchSignature = signature
        Task.detached(priority: .utility) { await provider.prefetch(pairs: pairs) }
    }

    private func installPlan(_ plan: AutoMixPlan?, trackedEntry: UUID, target: QueueEntry) {
        guard let tracked, tracked.entry.id == trackedEntry,
              let index = naturalNextIndex(), order.indices.contains(index), order[index].id == target.id else { return }
        if let session = mixSession, session.phase != .planned { return }
        guard let plan else {
            autoMixNote = "Couldn\u{2019}t reach AutoMix on your server"
            return
        }
        guard plan.isMix, let a = plan.a, let b = plan.b else {
            autoMixNote = plan.mode == .gapless ? "Gapless: these songs run into each other" : "No transition for this pair"
            return
        }
        // Not enough of A left to pre-roll B: keep the gapless handover for this pair.
        guard elapsedNow() < a.start - 1.5 else {
            autoMixNote = "Too close to the end to blend this time"
            return
        }
        mixSession = MixSession(plan: plan, a: a, b: b, outgoing: tracked, target: target)
        plannedMix = PlannedMix(plan: plan, from: tracked.entry.song, to: target.song)
        autoMixNote = plan.final == true ? nil : "Still analysing one of these songs: a smooth crossfade for now"
        Log.playback.info("AutoMix planned: \(plan.mode.rawValue) at \(String(format: "%.2f", a.start))s (\(plan.reason ?? ""))")
    }

    private func takeSpareDeck() -> AVQueuePlayer {
        if let tail = mixTail, tail.player === spareDeck { return AVQueuePlayer() }
        return spareDeck
    }

    // MARK: Tick (4 Hz, from the main player's time observer)

    func autoMixTick() {
        tickTail()
        guard let session = mixSession else { return }
        let t = elapsedNow()
        if session.phase != .scheduled, session.phase != .mixing { rampOutgoing(session, at: t) }
        switch session.phase {
        case .planned:
            if session.plan.final != true, ProcessInfo.processInfo.systemUptime - session.fetchedAt > 20,
               t < session.a.start - prepareLead - 5 {
                session.fetchedAt = ProcessInfo.processInfo.systemUptime
                refreshProvisionalPlan(session)
            }
            if t >= session.a.start - prepareLead, isPlaying {
                if t > session.a.start - 1.0 { cancelMix(reprepare: false) } else { beginPreparing(session) }
            }
        case .preparing:
            if t > session.a.start - 0.4 {
                Log.playback.warning("AutoMix: incoming song not ready in time, playing gapless")
                cancelMix(reprepare: true)
            }
        case .ready:
            if isPlaying, player.rate > 0 { schedule(session) }
            else if t > session.a.start - 0.4 { cancelMix(reprepare: true) }
        case .scheduled:
            if t >= session.a.start {
                session.phase = .mixing
                autoMixActive = true
            }
        case .mixing:
            if t >= (session.a.handoff ?? session.a.start) { handOff(session) }
        }
    }

    /// A eases into the blend tempo in the bars before B comes in (only when the tempos meet halfway).
    private func rampOutgoing(_ session: MixSession, at t: Double) {
        guard let ramp = session.a.rateRamp, tracked === session.outgoing else { return }
        while session.aRampIndex < ramp.count, ramp[session.aRampIndex].count >= 2, t >= ramp[session.aRampIndex][0] {
            let rate = Float(ramp[session.aRampIndex][1])
            player.defaultRate = rate
            if player.rate > 0 { player.rate = rate }
            session.aRampIndex += 1
        }
    }

    private func refreshProvisionalPlan(_ session: MixSession) {
        guard let provider = services.autoMix else { return }
        let fromId = session.outgoing.entry.song.id, toId = session.target.song.id
        let trackedEntry = session.outgoing.entry.id, target = session.target
        autoMixPlanTask = Task { [weak self] in
            let plan = await provider.plan(from: fromId, to: toId)
            guard !Task.isCancelled, let self, let plan, plan.final == true,
                  let current = self.mixSession, current === session, current.phase == .planned else { return }
            self.mixSession = nil
            self.installPlan(plan, trackedEntry: trackedEntry, target: target)
        }
    }

    // MARK: Preparing the incoming deck

    private func beginPreparing(_ session: MixSession) {
        guard let resolved = resolve(session.target.song) else {
            cancelMix(reprepare: true)
            return
        }
        session.phase = .preparing
        // A must not advance to its queued gapless successor any more: the incoming deck takes over.
        for item in player.items() where item !== session.outgoing.item { player.remove(item) }
        nextPrepared?.observations.removeAll()
        nextPrepared = nil

        attachTap(session.outgoing)
        session.outgoing.automation.set(deck: session.a)

        let incoming = makePrepared(entry: session.target, resolved: resolved)
        incoming.automation.set(deck: session.b)
        incoming.item.audioTimePitchAlgorithm = .spectral
        session.incoming = incoming
        let deck = takeSpareDeck()
        session.deck = deck
        deck.pause()
        deck.removeAllItems()
        deck.actionAtItemEnd = .advance
        deck.automaticallyWaitsToMinimizeStalling = false
        deck.defaultRate = session.rate
        deck.volume = deckVolume(for: session.target.song)
        deck.insert(incoming.item, after: nil)
        session.statusObservation = incoming.item.observe(\.status, options: [.initial, .new]) { [weak self, weak session] item, _ in
            let status = item.status
            Task { @MainActor in
                guard let self, let session, self.mixSession === session else { return }
                if status == .readyToPlay, session.phase == .preparing {
                    self.preroll(session)
                } else if status == .failed {
                    Log.playback.error("AutoMix: incoming item failed: \(item.error?.localizedDescription ?? "unknown")")
                    self.cancelMix(reprepare: true)
                }
            }
        }
    }

    func attachTap(_ prepared: PreparedItem) {
        guard !prepared.tapRequested else { return }
        prepared.tapRequested = true
        Task { [weak prepared] in
            guard let prepared else { return }
            prepared.tapAttached = await MixTap.attach(to: prepared.item, automation: prepared.automation)
        }
    }

    private func preroll(_ session: MixSession) {
        guard let deck = session.deck else { return }
        let start = CMTime(seconds: session.b.start, preferredTimescale: 600_000)
        deck.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak session] done in
            Task { @MainActor in
                guard let self, let session, self.mixSession === session, session.phase == .preparing else { return }
                guard done, deck.status == .readyToPlay else {
                    self.cancelMix(reprepare: true)
                    return
                }
                deck.preroll(atRate: session.rate) { [weak self, weak session] _ in
                    Task { @MainActor in
                        guard let self, let session, self.mixSession === session, session.phase == .preparing else { return }
                        session.phase = .ready
                        if self.isPlaying, self.player.rate > 0 { self.schedule(session) }
                    }
                }
            }
        }
    }

    /// Starts B at the host time A reaches `a.start`: both decks then run off the same clock, beat for beat.
    private func schedule(_ session: MixSession) {
        guard session.phase == .ready, let deck = session.deck, let timebase = session.outgoing.item.timebase else { return }
        // The host-time conversion below assumes A already runs at its blend tempo.
        guard abs(player.rate - session.aRate) < 0.0005 else {
            if (session.a.rateRamp ?? []).isEmpty, player.rate > 0 { player.rate = session.aRate }
            return
        }
        let hostClock = CMClockGetHostTimeClock()
        let startOnA = CMTime(seconds: session.a.start, preferredTimescale: 600_000)
        let hostStart = CMSyncConvertTime(startOnA, from: timebase, to: hostClock)
        let now = CMClockGetTime(hostClock)
        guard hostStart.isValid, (hostStart - now).seconds > 0.05 else {
            cancelMix(reprepare: true)
            return
        }
        deck.automaticallyWaitsToMinimizeStalling = false
        deck.setRate(session.rate, time: CMTime(seconds: session.b.start, preferredTimescale: 600_000),
                     atHostTime: hostStart)
        session.phase = .scheduled
        Log.playback.info("AutoMix scheduled in \(String(format: "%.2f", (hostStart - now).seconds))s at rate \(String(format: "%.4f", session.rate))")
    }

    // MARK: Handoff and tail

    /// B becomes the current song (UI, lock screen, scrobbling); A keeps fading out on its old deck.
    private func handOff(_ session: MixSession) {
        guard let incoming = session.incoming, let deck = session.deck else {
            cancelMix(reprepare: true)
            return
        }
        let outgoingPlayer = player
        uninstallPlayerObservers()
        player = deck
        spareDeck = outgoingPlayer          // busy until the tail ends; `takeSpareDeck` knows
        installPlayerObservers()
        player.automaticallyWaitsToMinimizeStalling = false
        player.defaultRate = session.rate
        session.statusObservation = nil
        mixSession = nil

        scrobbler.end()
        tracked?.observations.removeAll()
        tracked = incoming
        nextPrepared = nil
        seekGeneration += 1
        seekTarget = nil
        publishCurrent(incoming, startAt: elapsedNow(), playing: true)
        let curves = [session.b.gain, session.b.hpf, session.b.lpf, session.b.rateRamp ?? []]
        let automationEnd = curves.compactMap { $0.last?.first }.max() ?? 0
        mixTail = MixTail(player: outgoingPlayer, prepared: session.outgoing, stopAt: session.a.stop ?? session.a.start,
                          outgoingRate: session.aRate, automationEnd: automationEnd, ramp: session.b.rateRamp ?? [])
        applyVolume()
        prepareNext()
        syncCache()
        saveQueueSoon()
        Log.playback.info("AutoMix handoff to \(incoming.entry.song.title)")
    }

    private func tickTail() {
        guard let tail = mixTail else { return }
        if !tail.finished {
            let t = tail.player.currentTime().seconds
            if t.isFinite, t >= tail.stopAt { stopOutgoing(tail) }
        }
        let bTime = elapsedNow()
        while tail.rampIndex < tail.ramp.count, tail.ramp[tail.rampIndex].count >= 2, bTime >= tail.ramp[tail.rampIndex][0] {
            let rate = Float(tail.ramp[tail.rampIndex][1])
            player.defaultRate = rate
            if player.rate > 0 { player.rate = rate }
            tail.rampIndex += 1
        }
        if tail.finished, tail.rampIndex >= tail.ramp.count, bTime >= tail.automationEnd { endTail(tail) }
    }

    private func stopOutgoing(_ tail: MixTail) {
        tail.finished = true
        tail.player.pause()
        tail.player.removeAllItems()
        tail.prepared.observations.removeAll()
        tail.prepared.automation.clear()
    }

    private func endTail(_ tail: MixTail) {
        if !tail.finished { stopOutgoing(tail) }
        player.defaultRate = 1
        if player.rate > 0, abs(player.rate - 1) > 0.0001 { player.rate = 1 }
        player.automaticallyWaitsToMinimizeStalling = true
        tracked?.automation.clear()
        tail.player.automaticallyWaitsToMinimizeStalling = true
        tail.player.defaultRate = 1
        tail.player.volume = 1
        spareDeck = tail.player
        mixTail = nil
        autoMixActive = false
    }

    // MARK: Interruptions (user actions mid-transition)

    /// Drops a planned/prepared transition. `reprepare` restores the gapless successor on the main deck.
    func cancelMix(reprepare: Bool) {
        autoMixPlanTask?.cancel()
        guard let session = mixSession else { return }
        mixSession = nil
        plannedMix = nil
        if mixTail == nil { autoMixActive = false }
        session.statusObservation = nil
        if let deck = session.deck {
            deck.pause()
            deck.removeAllItems()
            deck.automaticallyWaitsToMinimizeStalling = true
            deck.defaultRate = 1
        }
        session.incoming?.observations.removeAll()
        session.outgoing.automation.clear()
        if tracked === session.outgoing, player.defaultRate != 1 {
            // A may have started easing into the blend tempo: back to its own.
            player.defaultRate = 1
            if player.rate > 0 { player.rate = 1 }
        }
        if reprepare, tracked === session.outgoing { prepareNextWithoutAutoMix() }
    }

    /// Ends any transition at once: the incoming song plays alone at its own tempo, or the mix is dropped.
    func settleAutoMix(keepIncoming: Bool) {
        if let session = mixSession {
            if keepIncoming, session.phase == .mixing || session.phase == .scheduled, session.incoming != nil {
                if session.phase == .scheduled { session.deck?.rate = session.rate }
                handOff(session)
            } else {
                cancelMix(reprepare: false)
            }
        }
        if let tail = mixTail {
            tail.ramp = []
            endTail(tail)
        }
    }

    /// Pauses every deck that is sounding.
    func pauseAutoMixDecks() {
        if let session = mixSession {
            switch session.phase {
            case .scheduled:
                session.deck?.pause()           // cancels the pending start; rescheduled on resume
                session.phase = .ready
            case .mixing:
                session.deck?.pause()
            default: break
            }
        }
        mixTail?.player.pause()
    }

    /// Resumes the main deck together with any deck mid-transition, on one shared host time so they stay locked.
    /// Returns false when nothing special is going on (the caller just plays).
    func resumeAutoMixDecks() -> Bool {
        let other: AVQueuePlayer
        let otherRate: Float
        if let session = mixSession, session.phase == .mixing, let deck = session.deck {
            other = deck
            otherRate = session.rate
        } else if let tail = mixTail, !tail.finished {
            other = tail.player
            otherRate = tail.outgoingRate
        } else {
            return false
        }
        let clock = CMClockGetHostTimeClock()
        let start = CMClockGetTime(clock) + CMTime(seconds: 0.12, preferredTimescale: 600_000)
        let mainRate = player.defaultRate > 0 ? player.defaultRate : 1
        player.automaticallyWaitsToMinimizeStalling = false
        other.automaticallyWaitsToMinimizeStalling = false
        player.setRate(mainRate, time: player.currentTime(), atHostTime: start)
        other.setRate(otherRate, time: other.currentTime(), atHostTime: start)
        return true
    }

    // MARK: Preview

    /// Jumps to a few seconds before the planned transition so it can be heard right away.
    func previewAutoMix() {
        guard let session = mixSession, session.phase == .planned, tracked === session.outgoing else { return }
        if !isPlaying { resume() }
        seek(to: max(0, session.a.start - 12))
    }

    var canPreviewAutoMix: Bool {
        guard let session = mixSession else { return false }
        return session.phase == .planned && tracked === session.outgoing
    }

    func autoMixMatches(after songId: String) async -> [String] {
        await services.autoMix?.matches(after: songId) ?? []
    }

    func autoMixSummary(songId: String) async -> AutoMixTrackSummary? {
        await services.autoMix?.summary(songId: songId)
    }

    // MARK: Helpers

    func deckVolume(for song: Song) -> Float {
        _volume * replayGainFactor(for: song) * sleepFade
    }

    func applyDeckVolumes() {
        if let tail = mixTail, !tail.finished { tail.player.volume = deckVolume(for: tail.prepared.entry.song) }
        if let session = mixSession, let deck = session.deck { deck.volume = deckVolume(for: session.target.song) }
    }

    func uninstallPlayerObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations.forEach { $0.invalidate() }
        playerObservations = []
    }
}
