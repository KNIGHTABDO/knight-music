import MediaPlayer
import UIKit

/// Decides who owns playback, the lock screen and the remote commands: Knight Music's music or a Streamora movie.
/// A movie takes focus when it starts playing (music pauses); music gets it back when the movie closes or when
/// you switch back to Knight Music (the movie pauses). Knight Music's RemoteCommands/NowPlayingCenter stay quiet
/// while `movieHasFocus` is set, and the movie engine stays quiet otherwise.
@MainActor
final class DuetMedia {
    static let shared = DuetMedia()

    /// Read from remote-command handlers on any thread, written on the main actor only.
    nonisolated(unsafe) static var movieHasFocus = false

    enum Source: Hashable { case engine, classic, web }

    /// Set by the Streamora bridge: pause whatever movie is playing (VLC engine, classic player or a <video>).
    var pauseMovie: (() -> Void)?
    /// Set by the Streamora bridge: put the movie back on the lock screen after music had it.
    var reclaimMovie: (() -> Void)?

    private(set) var activeSources: Set<Source> = []
    /// Music that a movie interrupted; it resumes when the movie ends or you switch back (Intermission).
    private var interruptedMusic: (entryID: UUID, intent: Int, accountID: UUID?)?
    private var releaseTask: Task<Void, Never>?

    var hasMovie: Bool { !activeSources.isEmpty }
    var interruptedSongTitle: String? {
        guard let app = AppModel.shared, canResumeMusic(app) else { return nil }
        return app.player.currentSong?.title
    }

    private func canResumeMusic(_ app: AppModel) -> Bool {
        guard let interruptedMusic else { return false }
        return app.player.currentEntry?.id == interruptedMusic.entryID
            && app.player.playbackLoadRevision == interruptedMusic.intent
            && app.activeAccount?.id == interruptedMusic.accountID
    }

    func movieStarted(_ source: Source) {
        releaseTask?.cancel()
        releaseTask = nil
        activeSources.insert(source)
        guard !Self.movieHasFocus else { return }
        Self.movieHasFocus = true
        if let app = AppModel.shared, app.player.isPlaying {
            let player = app.player
            player.pause()
            if DuetSettings.shared.intermission, let entry = player.currentEntry {
                interruptedMusic = (entry.id, player.playbackLoadRevision, app.activeAccount?.id)
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Music-only commands would show dead buttons (or act on paused music) next to the movie. The movie
        // re-enables the ones it handles in `reclaimMovie`; `RemoteCommands.refresh()` restores these for music.
        let c = MPRemoteCommandCenter.shared()
        for command in [c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand,
                        c.seekForwardCommand, c.seekBackwardCommand, c.likeCommand,
                        c.changeRepeatModeCommand, c.changeShuffleModeCommand] {
            command.isEnabled = false
        }
        reclaimMovie?()
        Log.app.info("duet: movie has focus (\(String(describing: source)))")
    }

    func movieStopped(_ source: Source) {
        activeSources.remove(source)
        guard activeSources.isEmpty, Self.movieHasFocus else { return }
        // Debounced (5 s): the web player closes the engine and reopens it when switching episodes or sources,
        // and resolving the next source can take a few seconds; releasing early would blip the music back on.
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.activeSources.isEmpty else { return }
            self.giveFocusToMusic(resume: true)
        }
    }

    /// Switching to Knight Music: the movie pauses and music gets the lock screen (and resumes if a movie stopped it).
    func musicTakesFocus() {
        releaseTask?.cancel()
        releaseTask = nil
        guard Self.movieHasFocus else { return }
        pauseMovie?()
        giveFocusToMusic(resume: true)
    }

    /// Music began playing on its own terms (Siri, a widget, the music UI) while a movie had focus.
    func musicStartedPlaying() {
        guard Self.movieHasFocus else { return }
        releaseTask?.cancel()
        pauseMovie?()
        giveFocusToMusic(resume: false)
    }

    private func giveFocusToMusic(resume: Bool) {
        releaseTask = nil
        Self.movieHasFocus = false
        defer { interruptedMusic = nil }
        guard let app = AppModel.shared else { return }
        let player = app.player
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        player.remote?.refresh()
        player.nowPlaying.republish()
        if resume, canResumeMusic(app), !player.isPlaying {
            player.resume()
        }
        Log.app.info("duet: music has focus")
    }
}
