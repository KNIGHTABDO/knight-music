import UIKit
import WebKit
import AVFoundation
import MediaPlayer
import MobileVLCKit

// Copied from the Streamora repo (app/plugin/ios/Sources/StreamoraPlayer, 71954a0). Duet changes: the lock screen
// is shared with Knight Music through DuetMedia (commands/info only while the movie has focus, never disabled on close).

// VLC drawing *behind* the web view: the web page turns transparent and keeps its own player controls on top
// (js/player/vlc.js drives this). The same trick camera-preview plugins use. VLC decodes on the device
// (VideoToolbox for H.264/HEVC) and reads RD's original file directly, so nothing waits on a transcode.
// Lock screen / Control Center: MPNowPlayingInfoCenter + MPRemoteCommandCenter (acts on VLC directly, then tells the page with a 'remote' {action, time?} event).
// Events: 'engine' {time, duration, playing, buffering, rate, width, height, ended?, error?} ~4×/s,
//         'tracks' {audio: [{id, name}], subs: [{id, name}], audioId, subId} when they change.
final class VlcEngine: NSObject {
    private let player = VLCMediaPlayer()
    // VLC hangs a tap recognizer on the drawable's superview: keep it on a container that never gets touches
    private let host = UIView()
    private let videoView = UIView()
    private weak var webView: WKWebView?
    private var savedBg: UIColor?
    private var savedScrollBg: UIColor?
    private var timer: Timer?
    private let send: (String, [String: Any]) -> Void

    private var lastTime: Int32 = -1
    private var sameTicks = 0
    private var everPlayed = false
    private var done = false
    private var knownDuration: Double = 0
    private var tracksKey = ""
    private var metaTitle = "", metaSubtitle = ""
    private var artwork: MPMediaItemArtwork?
    private var artworkURL: String?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var infoTicks = 0
    private var lastPlaying = false

    init?(webView: WKWebView, url: URL, start: Double, audioLang: String, title: String = "", subtitle: String = "", poster: String = "", send: @escaping (String, [String: Any]) -> Void) {
        guard let parent = webView.superview else { return nil }
        self.webView = webView
        self.send = send
        super.init()

        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.translatesAutoresizingMaskIntoConstraints = false
        parent.insertSubview(host, belowSubview: webView)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            host.topAnchor.constraint(equalTo: webView.topAnchor),
            host.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
        ])
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        videoView.frame = host.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(videoView)

        // see-through web view while playing (restored in close())
        savedBg = webView.backgroundColor
        savedScrollBg = webView.scrollView.backgroundColor
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true

        let media = VLCMedia(url: url)
        media.addOption(":network-caching=10000")   // a big cache is what keeps playback smooth on a shaky connection
        media.addOption(":http-reconnect")
        if start > 1 { media.addOption(":start-time=\(Int(start))") }
        if !audioLang.isEmpty { media.addOption(":audio-language=\(audioLang),any") }
        media.addOption(":sub-language=none")       // the web side picks subtitles (the file's or online ones)
        player.drawable = videoView
        player.media = media
        player.play()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        setMeta(title: title, subtitle: subtitle, poster: poster)
        setupRemote()
    }

    // MARK: - lock screen

    func setMeta(title: String, subtitle: String, poster: String) {
        guard !done else { return }
        metaTitle = title; metaSubtitle = subtitle
        if poster != artworkURL {
            artworkURL = poster; artwork = nil
            if !poster.isEmpty, let u = URL(string: poster) {
                URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
                    guard let data = data, let img = UIImage(data: data) else { return }
                    DispatchQueue.main.async {
                        guard let self = self, !self.done, self.artworkURL == poster else { return }
                        self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                        self.updateNowPlaying()
                    }
                }.resume()
            }
        }
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard !done, DuetMedia.movieHasFocus else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metaTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(max(0, player.time.intValue)) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if !metaSubtitle.isEmpty { info[MPMediaItemPropertyArtist] = metaSubtitle }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let a = artwork { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ f: @escaping (MPRemoteCommandEvent) -> Void) {
            cmd.isEnabled = true
            let t = cmd.addTarget { [weak self] e in
                guard let self = self, !self.done, DuetMedia.movieHasFocus else { return .commandFailed }
                f(e)
                return .success
            }
            commandTargets.append((cmd, t))
        }
        add(c.playCommand) { [weak self] _ in self?.remotePlay() }
        add(c.pauseCommand) { [weak self] _ in self?.remotePause() }
        add(c.togglePlayPauseCommand) { [weak self] _ in
            guard let self = self else { return }
            if self.player.isPlaying { self.remotePause() } else { self.remotePlay() }
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        add(c.skipForwardCommand) { [weak self] _ in self?.remoteSkip(10) }
        add(c.skipBackwardCommand) { [weak self] _ in self?.remoteSkip(-10) }
        add(c.changePlaybackPositionCommand) { [weak self] e in
            guard let self = self, let pe = e as? MPChangePlaybackPositionCommandEvent else { return }
            self.remoteSeek(pe.positionTime)
        }
    }

    private func remotePlay() { play(); send("remote", ["action": "play"]); updateNowPlaying() }
    var isPlaying: Bool { !done && player.isPlaying }
    /// Pauses from the app side (leaving Streamora) and tells the page so its controls stay in step.
    func pauseFromApp() { if isPlaying { remotePause() } }
    /// The movie got the lock screen back from Knight Music.
    func reclaimLockScreen() {
        guard !done else { return }
        for (cmd, _) in commandTargets { cmd.isEnabled = true }
        updateNowPlaying()
    }
    private func remotePause() { pause(); send("remote", ["action": "pause"]); updateNowPlaying() }
    private func remoteSkip(_ d: Double) {
        let now = Double(max(0, player.time.intValue)) / 1000
        var t = max(0, now + d)
        if duration > 0 { t = min(t, max(0, duration - 1)) }
        remoteSeek(t)
    }
    private func remoteSeek(_ t: Double) {
        seek(t)
        send("remote", ["action": "seek", "time": t])
        updateNowPlaying()
    }

    func setAudioDelay(_ seconds: Double) { player.currentAudioPlaybackDelay = Int(seconds * 1_000_000) }

    // MARK: - controls (from JS)

    func play() { if !done { player.play() } }
    func pause() { if !done, player.canPause { player.pause() } }
    func seek(_ t: Double) {
        guard !done else { return }
        player.time = VLCTime(int: Int32(max(0, t) * 1000))
        sameTicks = 0
    }
    func setRate(_ r: Double) { player.rate = Float(r) }
    func setVolume(_ v: Double, muted: Bool) {
        if let a = player.audio as VLCAudio? {
            a.volume = Int32(max(0, min(1, v)) * 100)
            a.isMuted = muted
        }
    }
    func setAudio(_ id: Int32) { player.currentAudioTrackIndex = id; tracksKey = "" }
    func setSub(_ id: Int32) { player.currentVideoSubTitleIndex = id; tracksKey = "" }

    func close() {
        guard !done else { return }
        done = true
        timer?.invalidate()
        for (cmd, t) in commandTargets { cmd.removeTarget(t) }
        commandTargets = []
        // Knight Music shares these commands: DuetMedia hands them (and Now Playing) back to the music player.
        player.stop()
        host.removeFromSuperview()
        if let w = webView {
            w.isOpaque = true
            w.backgroundColor = savedBg
            w.scrollView.backgroundColor = savedScrollBg
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - state out

    private var duration: Double {
        let d = Double(player.media?.length.intValue ?? 0) / 1000
        if d > 0 { knownDuration = d }
        return knownDuration
    }

    private func tick() {
        guard !done else { return }
        let t = player.time.intValue
        if t != lastTime {
            lastTime = t; sameTicks = 0
            if t > 0 { everPlayed = true }
        } else { sameTicks += 1 }
        let paused = player.state == .paused
        // "buffering" = we mean to play and the picture hasn't moved for ¾ s (or hasn't started yet)
        let buffering = !paused && (!everPlayed || sameTicks >= 3)
        let size = player.videoSize
        var d: [String: Any] = [
            "time": Double(max(0, t)) / 1000, "duration": duration, "playing": player.isPlaying && !buffering,
            "paused": paused, "buffering": buffering, "rate": Double(player.rate),
            "width": Double(size.width), "height": Double(size.height)
        ]
        switch player.state {
        case .ended:
            d["ended"] = true
        case .stopped where everPlayed && duration > 0 && duration - Double(t) / 1000 < 5:
            d["ended"] = true
        case .error:
            d["error"] = everPlayed ? "The stream stopped." : "This file couldn't be played."
        default: break
        }
        send("engine", d)
        sendTracks()
        infoTicks += 1
        let playing = player.isPlaying
        if infoTicks % 8 == 0 || playing != lastPlaying { lastPlaying = playing; updateNowPlaying() }
    }

    private func sendTracks() {
        let an = (player.audioTrackNames as? [String]) ?? [], ai = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let sn = (player.videoSubTitlesNames as? [String]) ?? [], si = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let ca = player.currentAudioTrackIndex, cs = player.currentVideoSubTitleIndex
        let key = "\(an)|\(ai)|\(sn)|\(si)|\(ca)|\(cs)"
        guard key != tracksKey else { return }
        tracksKey = key
        func list(_ names: [String], _ ids: [NSNumber]) -> [[String: Any]] {
            zip(names, ids).map { ["id": $0.1.intValue, "name": $0.0] }
        }
        send("tracks", ["audio": list(an, ai), "subs": list(sn, si), "audioId": Int(ca), "subId": Int(cs)])
    }
}
