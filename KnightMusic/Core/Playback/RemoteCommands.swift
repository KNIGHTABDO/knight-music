import MediaPlayer

/// Lock screen / Control Center / headset commands.
@MainActor
final class RemoteCommands {
    private weak var engine: PlayerEngine?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var seekTask: Task<Void, Never>?

    init(engine: PlayerEngine) {
        self.engine = engine
        install()
    }

    private func add(_ command: MPRemoteCommand,
                     _ handler: @escaping @MainActor (PlayerEngine, MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] event in
            Task { @MainActor in
                guard let engine = self?.engine else { return }
                handler(engine, event)
            }
            return .success
        }
        targets.append((command, token))
    }

    private func install() {
        let c = MPRemoteCommandCenter.shared()
        add(c.playCommand) { e, _ in e.resume() }
        add(c.pauseCommand) { e, _ in e.pause() }
        add(c.togglePlayPauseCommand) { e, _ in e.togglePlayPause() }
        add(c.nextTrackCommand) { e, _ in e.next() }
        add(c.previousTrackCommand) { e, _ in e.previous() }
        add(c.changePlaybackPositionCommand) { e, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { e.seek(to: event.positionTime) }
        }
        add(c.seekForwardCommand) { [weak self] e, event in
            self?.handleSeek(engine: e, event: event, delta: 10)
        }
        add(c.seekBackwardCommand) { [weak self] e, event in
            self?.handleSeek(engine: e, event: event, delta: -10)
        }
        add(c.likeCommand) { e, _ in e.toggleStarCurrent() }
        add(c.changeRepeatModeCommand) { e, event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return }
            switch event.repeatType {
            case .off: e.setRepeat(.off)
            case .one: e.setRepeat(.one)
            case .all: e.setRepeat(.all)
            @unknown default: break
            }
        }
        add(c.changeShuffleModeCommand) { e, event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return }
            e.setShuffle(event.shuffleType != .off)
        }
        c.likeCommand.localizedTitle = "Favorite"
        c.likeCommand.localizedShortTitle = "Favorite"
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        refresh()
    }

    func cancelSeeking() {
        seekTask?.cancel()
        seekTask = nil
    }

    private func handleSeek(engine: PlayerEngine, event: MPRemoteCommandEvent, delta: TimeInterval) {
        guard engine.currentRadio == nil, let seekEvent = event as? MPSeekCommandEvent else { return }
        switch seekEvent.type {
        case .beginSeeking:
            cancelSeeking()
            seekTask = Task { @MainActor [weak self, weak engine] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, let engine else { break }
                    let maxTime = max(0, engine.duration - 1)
                    let newTime = min(max(engine.currentTime + delta, 0), maxTime)
                    engine.seek(to: newTime)
                }
                self?.seekTask = nil
            }
        case .endSeeking:
            cancelSeeking()
        @unknown default:
            break
        }
    }

    /// Re-sync enabled/active states with the engine (call after queue/song/repeat/shuffle changes).
    func refresh() {
        guard let engine else { return }
        let c = MPRemoteCommandCenter.shared()
        let live = engine.currentRadio != nil
        c.nextTrackCommand.isEnabled = !live && engine.hasNext
        c.previousTrackCommand.isEnabled = !live && engine.currentSong != nil
        c.changePlaybackPositionCommand.isEnabled = !live
        c.seekForwardCommand.isEnabled = !live && engine.currentSong != nil
        c.seekBackwardCommand.isEnabled = !live && engine.currentSong != nil
        c.likeCommand.isEnabled = !live && engine.currentSong != nil
        c.likeCommand.isActive = !live && engine.currentSong?.starred != nil
        c.changeRepeatModeCommand.isEnabled = !live
        c.changeShuffleModeCommand.isEnabled = !live
        switch engine.repeatMode {
        case .off: c.changeRepeatModeCommand.currentRepeatType = .off
        case .one: c.changeRepeatModeCommand.currentRepeatType = .one
        case .all: c.changeRepeatModeCommand.currentRepeatType = .all
        }
        c.changeShuffleModeCommand.currentShuffleType = engine.shuffleEnabled ? .items : .off
    }
}
