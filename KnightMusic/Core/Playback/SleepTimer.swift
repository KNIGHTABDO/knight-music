import Foundation

/// Sleep timer with a 10 s volume fade. "End of song" mode is enforced by the engine (it stops preloading
/// the next item and pauses on the next song), so it is sample-accurate.
@MainActor @Observable
final class SleepTimer {
    enum Mode: Equatable {
        case duration(minutes: Int)
        case endOfSong
    }

    static let presetMinutes = [5, 10, 15, 30, 45, 60]
    static let fadeSeconds: TimeInterval = 10

    private(set) var mode: Mode?
    /// Seconds left (duration mode: until pause; end-of-song mode: until the song ends). Nil when inactive.
    private(set) var remaining: TimeInterval?
    var isActive: Bool { mode != nil }

    @ObservationIgnored weak var player: PlayerEngine?
    @ObservationIgnored private var deadline: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(minutes: Int) {
        cancelWork()
        mode = .duration(minutes: minutes)
        deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        remaining = TimeInterval(minutes) * 60
        player?.armEndOfSongPause(false)
        run()
    }

    func startEndOfSong() {
        cancelWork()
        mode = .endOfSong
        deadline = nil
        player?.armEndOfSongPause(true)
        remaining = player.map { max($0.duration - $0.currentTime, 0) }
        run()
    }

    func cancel() {
        cancelWork()
        player?.armEndOfSongPause(false)
        player?.setSleepFade(1)
        mode = nil
        remaining = nil
    }

    /// Called by the engine when the armed end-of-song pause happened.
    func endOfSongReached() {
        cancelWork()
        player?.setSleepFade(1)
        mode = nil
        remaining = nil
    }

    private func cancelWork() {
        task?.cancel()
        task = nil
    }

    private func run() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player, let mode else { return }
        let left: TimeInterval
        switch mode {
        case .duration:
            left = max((deadline ?? Date()).timeIntervalSinceNow, 0)
        case .endOfSong:
            left = max(player.duration - player.currentTime, 0)
        }
        let rounded = left.rounded(.up)
        if remaining != rounded { remaining = rounded }
        if player.isPlaying {
            player.setSleepFade(left < Self.fadeSeconds ? Float(left / Self.fadeSeconds) : 1)
        }
        if case .duration = mode, left <= 0 {
            player.pause()
            player.setSleepFade(1)
            cancelWork()
            self.mode = nil
            remaining = nil
        }
    }
}
