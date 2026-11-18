// Copied from the Streamora repo (app/plugin/ios/Sources/StreamoraPlayer/PlayerViewController.swift, 71954a0), types renamed.
import UIKit
import AVFoundation
import MediaPlayer
import MobileVLCKit

struct StreamoraPlayerOptions {
    let url: URL
    let title: String
    let subtitle: String
    let start: Double
    let hasNext: Bool
    let audioLang: String   // ISO 639-2 (eng, fre…) from Streamora's settings
    let subsLang: String    // ISO 639-2, or "off"
}

/// A subtitle file from OpenSubtitles (the web player's source), offered next to the file's own tracks.
struct StreamoraOnlineSub {
    let label: String
    let lang: String
    let url: URL
}

// Full-screen VLC player. VLC reads RD's original file over HTTP range requests and decodes it on the device
// (VideoToolbox for H.264/HEVC), so nothing waits on RD's live transcode.
final class StreamoraPlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private let opts: StreamoraPlayerOptions
    private let send: (String, [String: Any]) -> Void
    /// Duet: called once when the player closes for any reason (DuetMedia gives the lock screen back to music).
    var onFinish: (() -> Void)?
    /// Duet: called when the viewer resumes playback (the movie takes the focus back from music).
    var onPlay: (() -> Void)?
    private let player = VLCMediaPlayer()

    // VLC adds its own tap recognizer to the drawable's superview, which used to swallow every tap (no controls).
    // The drawable sits in a container that ignores touches, so that recognizer never fires.
    private let videoHost = UIView()
    private let videoView = UIView()
    private let overlay = UIView()
    private let skipBtn = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let subLabel = UILabel()
    private let playBtn = UIButton(type: .system)
    private let slider = UISlider()
    private let curLabel = UILabel()
    private let durLabel = UILabel()
    private let audioBtn = UIButton(type: .system)
    private let subsBtn = UIButton(type: .system)
    private let fillBtn = UIButton(type: .system)

    private var timer: Timer?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var hideWork: DispatchWorkItem?
    private var scrubbing = false
    private var finished = false
    private var fill = false
    private var everPlayed = false
    private var lastTime: Int32 = -1
    private var sameTicks = 0
    private var lastReport = Date.distantPast
    private var knownDuration: Double = 0
    private var reportedDuration: Double = 0
    private var onlineSubs: [StreamoraOnlineSub] = []
    private var addedSubs: [URL: Bool] = [:]
    private var autoSubDone = false
    private var intro: (Double, Double)?
    private var outro: (Double, Double)?

    init(options: StreamoraPlayerOptions, send: @escaping (String, [String: Any]) -> Void) {
        self.opts = options
        self.send = send
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    // MARK: - lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        videoHost.frame = view.bounds
        videoHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoHost.isUserInteractionEnabled = false
        view.addSubview(videoHost)
        videoView.frame = videoHost.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        videoHost.addSubview(videoView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()

        buildOverlay()
        buildSkip()
        buildGestures()

        let media = VLCMedia(url: opts.url)
        // a big network cache is what keeps playback smooth on a shaky connection
        media.addOption(":network-caching=10000")
        media.addOption(":http-reconnect")
        if opts.start > 1 { media.addOption(":start-time=\(Int(max(0, min(opts.start.isFinite ? opts.start : 0, 1_000_000))))") }
        // the file's own tracks in the viewer's languages (fall back to whatever the file prefers)
        if !opts.audioLang.isEmpty { media.addOption(":audio-language=\(opts.audioLang),any") }
        media.addOption(opts.subsLang == "off" || opts.subsLang.isEmpty ? ":sub-language=none" : ":sub-language=\(opts.subsLang)")
        player.drawable = videoView
        player.media = media
        player.play()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        UIApplication.shared.isIdleTimerDisabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(appBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        setupRemote()
        scheduleHide()
    }

    /// Lock screen / headset play-pause while the classic player has the movie focus (Knight Music's commands stay quiet then).
    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ f: @escaping (VLCMediaPlayer) -> Void) {
            cmd.isEnabled = true
            let t = cmd.addTarget { [weak self] _ in
                guard let self = self, !self.finished, DuetMedia.movieHasFocus else { return .commandFailed }
                f(self.player)
                return .success
            }
            commandTargets.append((cmd, t))
        }
        add(c.playCommand) { [weak self] p in self?.onPlay?(); p.play() }
        add(c.pauseCommand) { p in if p.canPause { p.pause() } }
        add(c.togglePlayPauseCommand) { [weak self] p in if p.isPlaying { p.pause() } else { self?.onPlay?(); p.play() } }
    }

    private func updateNowPlaying() {
        guard !finished, DuetMedia.movieHasFocus else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: opts.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if !opts.subtitle.isEmpty { info[MPMediaItemPropertyArtist] = opts.subtitle }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFill()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
    }

    // MARK: - state

    private var position: Double { Double(player.time.intValue) / 1000 }
    private var duration: Double {
        let d = Double(player.media?.length.intValue ?? 0) / 1000
        if d > 0 { knownDuration = d }
        return knownDuration
    }

    private func tick() {
        guard !finished else { return }
        let t = player.time.intValue
        let playing = player.isPlaying
        if t != lastTime {
            lastTime = t; sameTicks = 0
            if t > 0 && !everPlayed { everPlayed = true; scheduleHide() }
        } else { sameTicks += 1 }
        if everPlayed { autoSub() }
        updateSkip()
        // spinner only when we mean to play and the picture hasn't moved for a second
        let stuck = player.state != .paused && sameTicks >= 2
        if stuck || !everPlayed { spinner.startAnimating() } else { spinner.stopAnimating() }

        let d = duration
        // The web app checks identity before recording progress. Older builds still fall back to progress events.
        if d > 0 && d != reportedDuration {
            reportedDuration = d
            send("metadata", ["duration": d])
        }
        if !scrubbing && d > 0 { slider.value = Float(position / d) }
        if !scrubbing { curLabel.text = fmt(position) }
        durLabel.text = d > 0 ? fmt(d) : "--:--"
        playBtn.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: big), for: .normal)

        switch player.state {
        case .ended:
            finish(ended: true)
            return
        case .error:
            finish(error: everPlayed ? "The stream stopped." : "This file couldn't be played.")
            return
        case .stopped where everPlayed && d > 0 && d - position < 5:
            finish(ended: true)
            return
        default: break
        }
        if Date().timeIntervalSince(lastReport) >= 5 { report(); updateNowPlaying() }
    }

    private func report() {
        lastReport = Date()
        guard everPlayed else { return }
        send("progress", ["position": position, "duration": duration, "paused": !player.isPlaying])
    }

    @objc private func appBackground() { report() }

    func finish(ended: Bool = false, error: String? = nil, notify: Bool = true) {
        guard !finished else { return }
        finished = true
        onFinish?()
        let d = duration
        let t = ended ? d : (everPlayed ? position : opts.start)
        timer?.invalidate()
        hideWork?.cancel()
        for (cmd, t) in commandTargets { cmd.removeTarget(t) }
        commandTargets = []
        player.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if notify {
            var data: [String: Any] = ["position": t, "duration": d, "ended": ended]
            if let e = error { data["error"] = e }
            send("closed", data)
        }
        // From the presenter: on the player itself, dismiss only closes the track sheet when one is open (the
        // movie ending under it left a dead player on screen).
        (presentingViewController ?? self).dismiss(animated: true)
    }

    // MARK: - extras from the web side (online subtitles, intro times); they can arrive after playback starts

    func setExtras(subs: [StreamoraOnlineSub], intro: (Double, Double)?, outro: (Double, Double)?) {
        onlineSubs = subs
        self.intro = intro
        self.outro = outro
        autoSubDone = false
    }

    // The file has no subtitle track in the viewer's language (VLC picked none): use the best online one.
    private func autoSub() {
        guard !autoSubDone, sameTicks == 0 else { return }
        if opts.subsLang == "off" || opts.subsLang.isEmpty { autoSubDone = true; return }
        guard !onlineSubs.isEmpty else { return }
        autoSubDone = true
        if player.currentVideoSubTitleIndex >= 0 { return }
        if let s = onlineSubs.first(where: { $0.lang == opts.subsLang }) { useOnline(s) }
    }

    private func useOnline(_ s: StreamoraOnlineSub) {
        if addedSubs[s.url] == nil {
            addedSubs[s.url] = true
            _ = player.addPlaybackSlave(s.url, type: .subtitle, enforce: true)
        } else if let i = ((player.videoSubTitlesNames as? [String]) ?? []).lastIndex(where: { $0.contains(s.url.lastPathComponent) }),
                  let ids = player.videoSubTitlesIndexes as? [NSNumber], i < ids.count {
            player.currentVideoSubTitleIndex = ids[i].int32Value
        } else {
            _ = player.addPlaybackSlave(s.url, type: .subtitle, enforce: true)
        }
    }

    private func buildSkip() {
        skipBtn.setTitle("Skip intro", for: .normal)
        skipBtn.setImage(UIImage(systemName: "forward.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)), for: .normal)
        skipBtn.tintColor = .black
        skipBtn.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        skipBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        skipBtn.layer.cornerRadius = 22
        skipBtn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 20)
        skipBtn.addTarget(self, action: #selector(tapSkip), for: .touchUpInside)
        skipBtn.alpha = 0
        skipBtn.isHidden = true
        skipBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(skipBtn)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            skipBtn.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            skipBtn.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -96),
            skipBtn.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private var skipTarget: Double? {
        let p = position
        if let i = intro, p >= i.0, p < i.1 - 1 { return i.1 }
        if let o = outro, p >= o.0, p < o.1 - 1, !opts.hasNext { return o.1 }
        return nil
    }

    private func updateSkip() {
        let on = everPlayed && skipTarget != nil
        if on == !skipBtn.isHidden { return }
        if let o = outro, position >= o.0 { skipBtn.setTitle("Skip credits", for: .normal) } else { skipBtn.setTitle("Skip intro", for: .normal) }
        if on { skipBtn.isHidden = false }
        UIView.animate(withDuration: 0.2, animations: { self.skipBtn.alpha = on ? 1 : 0 }) { _ in if !on { self.skipBtn.isHidden = true } }
    }

    @objc private func tapSkip() {
        guard let t = skipTarget else { return }
        player.time = VLCTime(int: t.vlcMillis)
        sameTicks = 0
    }

    // MARK: - UI

    private let big = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
    private let small = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)

    @discardableResult
    private func button(_ b: UIButton = UIButton(type: .system), _ symbol: String, _ cfg: UIImage.SymbolConfiguration, _ action: Selector, _ label: String) -> UIButton {
        b.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.accessibilityLabel = label
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }

    private func buildOverlay() {
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        view.addSubview(overlay)
        let g = overlay.safeAreaLayoutGuide

        // top: close + titles
        let close = button(UIButton(type: .system), "xmark", small, #selector(tapClose), "Close")
        titleLabel.text = opts.title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        subLabel.text = opts.subtitle
        subLabel.font = .systemFont(ofSize: 14)
        subLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        let titles = UIStackView(arrangedSubviews: [titleLabel, subLabel])
        titles.axis = .vertical
        let top = UIStackView(arrangedSubviews: [close, titles])
        top.spacing = 8
        top.alignment = .center
        top.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(top)

        // center: -10, play, +10
        let back = button(UIButton(type: .system), "gobackward.10", big, #selector(tapBack), "Back 10 seconds")
        button(playBtn, "pause.fill", big, #selector(tapPlay), "Play or pause")
        let fwd = button(UIButton(type: .system), "goforward.10", big, #selector(tapFwd), "Forward 10 seconds")
        let mid = UIStackView(arrangedSubviews: [back, playBtn, fwd])
        mid.spacing = 48
        mid.alignment = .center
        mid.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(mid)

        // bottom: time, slider, time, then track buttons
        for l in [curLabel, durLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            l.textColor = .white
            l.text = "--:--"
            l.setContentHuggingPriority(.required, for: .horizontal)
        }
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubMove), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let bar = UIStackView(arrangedSubviews: [curLabel, slider, durLabel])
        bar.spacing = 10
        bar.alignment = .center

        button(audioBtn, "speaker.wave.2", small, #selector(tapAudio), "Audio track")
        button(subsBtn, "captions.bubble", small, #selector(tapSubs), "Subtitles")
        button(fillBtn, "arrow.up.left.and.arrow.down.right", small, #selector(tapFill), "Fill screen")
        var tools: [UIView] = [audioBtn, subsBtn, fillBtn, UIView()]
        if opts.hasNext {
            let next = UIButton(type: .system)
            next.setTitle("Next episode", for: .normal)
            next.setImage(UIImage(systemName: "forward.end.fill", withConfiguration: small), for: .normal)
            next.tintColor = .white
            next.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            next.addTarget(self, action: #selector(tapNext), for: .touchUpInside)
            tools.append(next)
        }
        let toolRow = UIStackView(arrangedSubviews: tools)
        toolRow.spacing = 16
        toolRow.alignment = .center
        let bottom = UIStackView(arrangedSubviews: [bar, toolRow])
        bottom.axis = .vertical
        bottom.spacing = 6
        bottom.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(bottom)

        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -12),
            top.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            mid.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            mid.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            bottom.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8)
        ])
    }

    private func buildGestures() {
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(toggleOverlay))
        single.require(toFail: dbl)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for r in [dbl, single, pinch] as [UIGestureRecognizer] {
            r.cancelsTouchesInView = false
            r.delegate = self
            view.addGestureRecognizer(r)
        }
    }

    // never let some other recognizer (VLC's, the system's) block ours
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view !== view
    }

    // taps on buttons go to the buttons
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    private func showOverlay(_ on: Bool) {
        UIView.animate(withDuration: 0.2) { self.overlay.alpha = on ? 1 : 0 }
        if on { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.player.isPlaying, !self.scrubbing, self.presentedViewController == nil else { return }
            self.showOverlay(false)
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    @objc private func toggleOverlay(_ r: UITapGestureRecognizer) {
        showOverlay(overlay.alpha < 0.5)
    }

    @objc private func doubleTap(_ r: UITapGestureRecognizer) {
        if r.location(in: view).x < view.bounds.width / 2 { player.jumpBackward(10) } else { player.jumpForward(10) }
        sameTicks = 0
        if overlay.alpha > 0.5 { scheduleHide() }
    }

    @objc private func pinched(_ r: UIPinchGestureRecognizer) {
        guard r.state == .ended else { return }
        if (r.scale > 1) != fill { tapFill() }
    }

    // MARK: - actions

    @objc private func tapClose() { finish() }
    @objc private func tapPlay() {
        if player.isPlaying { player.pause() } else { onPlay?(); player.play() }
        scheduleHide()
    }

    /// Duet: switching to Knight Music pauses the movie (the viewer resumes it with the play button).
    func pauseFromApp() {
        guard !finished, player.isPlaying else { return }
        player.pause()
        report()
        showOverlay(true)
    }
    @objc private func tapBack() { player.jumpBackward(10); scheduleHide() }
    @objc private func tapFwd() { player.jumpForward(10); scheduleHide() }
    @objc private func tapNext() {
        report()
        send("next", [:])
        finish(notify: false)
    }

    @objc private func scrubStart() { scrubbing = true; hideWork?.cancel() }
    @objc private func scrubMove() { curLabel.text = fmt(Double(slider.value) * duration) }
    @objc private func scrubEnd() {
        if duration > 0 { player.time = VLCTime(int: (Double(slider.value) * duration).vlcMillis) }
        scrubbing = false
        sameTicks = 0
        scheduleHide()
    }

    @objc private func tapFill() {
        fill.toggle()
        fillBtn.setImage(UIImage(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", withConfiguration: small), for: .normal)
        UIView.animate(withDuration: 0.25) { self.applyFill() }
    }

    // zoom the fitted picture until it covers the screen (crops the edges)
    private func applyFill() {
        let vs = player.videoSize
        let W = view.bounds.width, H = view.bounds.height
        guard fill, vs.width > 0, vs.height > 0, W > 0, H > 0 else { videoView.transform = .identity; return }
        let fit = min(W / vs.width, H / vs.height)
        let k = max(W / (vs.width * fit), H / (vs.height * fit))
        videoView.transform = CGAffineTransform(scaleX: k, y: k)
    }

    @objc private func tapAudio() {
        let names = (player.audioTrackNames as? [String]) ?? []
        let ids = (player.audioTrackIndexes as? [NSNumber]) ?? []
        menu("Audio", names, ids, player.currentAudioTrackIndex, audioBtn) { [weak self] i in self?.player.currentAudioTrackIndex = i }
    }

    @objc private func tapSubs() {
        let names = (player.videoSubTitlesNames as? [String]) ?? []
        let ids = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        // online ones (OpenSubtitles), the viewer's language first, a handful per language
        var online: [StreamoraOnlineSub] = []
        var perLang: [String: Int] = [:]
        for s in onlineSubs.sorted(by: { ($0.lang == opts.subsLang ? 0 : 1) < ($1.lang == opts.subsLang ? 0 : 1) }) {
            let n = perLang[s.lang, default: 0]
            if n < 3 && online.count < 12 { online.append(s); perLang[s.lang] = n + 1 }
        }
        var extra: [(String, () -> Void)] = []
        for s in online {
            extra.append(("🌐 " + s.label, { [weak self] in self?.useOnline(s) }))
        }
        menu("Subtitles", names, ids, player.currentVideoSubTitleIndex, subsBtn, extra: extra) { [weak self] i in self?.player.currentVideoSubTitleIndex = i }
    }

    private func menu(_ title: String, _ names: [String], _ ids: [NSNumber], _ current: Int32, _ from: UIView,
                      extra: [(String, () -> Void)] = [], _ pick: @escaping (Int32) -> Void) {
        hideWork?.cancel()
        let sheet = UIAlertController(title: title, message: names.isEmpty && extra.isEmpty ? "No tracks in this file" : nil, preferredStyle: .actionSheet)
        for (name, id) in zip(names, ids) {
            let on = id.int32Value == current
            sheet.addAction(UIAlertAction(title: (on ? "✓ " : "") + name, style: .default) { [weak self] _ in pick(id.int32Value); self?.scheduleHide() })
        }
        for (name, run) in extra {
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in run(); self?.scheduleHide() })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.scheduleHide() })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = from
            pop.sourceRect = from.bounds
        }
        present(sheet, animated: true)
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--:--" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
