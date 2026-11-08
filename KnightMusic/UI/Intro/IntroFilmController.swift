import AVFoundation
import CoreImage
import UIKit

/// Plays the Duet film full screen and hands over to the app with Duet's own gesture: the last frame curls up
/// like a page and the live app is underneath. Skipping takes the same path from the current frame, and the
/// soundtrack fades out under the curl rather than stopping.
final class IntroFilmController: UIViewController {
    /// The end card has settled here (icon in place, before the film's own fade to black).
    private static let handoffTime = CMTime(seconds: 93.0, preferredTimescale: 600)
    private static let curlDuration: TimeInterval = 0.9

    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    private let skipDelay: TimeInterval
    private let onFinish: () -> Void

    private let filmView = IntroPlayerView()
    private let pageContainer = UIView()
    private let skipButton = UIButton(configuration: .glass())
    private var boundaryObserver: Any?
    private var observers: [NSObjectProtocol] = []
    private var handedOff = false
    private var finished = false
    private var previousCategory: AVAudioSession.Category?

    init(url: URL, skipDelay: TimeInterval, onFinish: @escaping () -> Void) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        self.skipDelay = skipDelay
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        item.add(output)
        player.preventsDisplaySleepDuringVideoPlayback = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        filmView.frame = view.bounds
        filmView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        filmView.backgroundColor = .black
        filmView.playerLayer.player = player
        filmView.playerLayer.videoGravity = .resizeAspect
        view.addSubview(filmView)

        pageContainer.frame = view.bounds
        pageContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageContainer.backgroundColor = .clear
        pageContainer.isUserInteractionEnabled = false
        view.addSubview(pageContainer)

        var config = UIButton.Configuration.glass()
        config.title = "Skip"
        config.image = UIImage(systemName: "forward.end.fill")
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 16)
        skipButton.configuration = config
        skipButton.alpha = 0
        skipButton.accessibilityHint = "Ends the film and opens Duet"
        skipButton.addAction(UIAction { [weak self] _ in self?.handoff() }, for: .primaryActionTriggered)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(skipButton)
        NSLayoutConstraint.activate([
            skipButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            skipButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: Self.handoffTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.handoff() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handoff() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.app.error("Intro film failed to play")
                self?.finish()
            }
        })
        // Leaving the app mid-film: no film waiting on return, just the app.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handedOff, player.timeControlStatus != .playing else { return }
        startAudio()
        player.play()
        UIView.animate(withDuration: 0.5, delay: skipDelay, options: [.allowUserInteraction, .curveEaseOut]) {
            self.skipButton.alpha = 1
        }
    }

    // MARK: - audio

    /// Solo ambient: the film respects the silent switch and doesn't ride over someone else's audio.
    private func startAudio() {
        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        do {
            try session.setCategory(.soloAmbient, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            Log.app.error("Intro audio session failed: \(error.localizedDescription)")
        }
    }

    private func restoreAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            // PlayerEngine re-activates .playback whenever it starts; leave the category ready for it.
            try session.setCategory(previousCategory ?? .playback, mode: .default)
        } catch {
            Log.app.error("Intro audio restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - handoff

    private func handoff() {
        guard !handedOff, !finished else { return }
        handedOff = true
        UIView.animate(withDuration: 0.2) { self.skipButton.alpha = 0 }

        guard let frame = currentFrame(), !UIAccessibility.isReduceMotionEnabled else {
            // No still to curl (or Reduce Motion): dissolve the film into the app instead.
            fadeOutAudio(over: 0.6)
            UIView.animate(withDuration: 0.6, delay: 0, options: .curveEaseInOut) {
                self.filmView.alpha = 0
            } completion: { _ in self.finish() }
            return
        }

        // The page: the exact frame on screen, letterbox included, so taking it over the film changes nothing.
        let page = UIImageView(image: frame)
        page.frame = pageContainer.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        page.contentMode = .scaleAspectFit
        page.backgroundColor = .black
        pageContainer.addSubview(page)
        filmView.isHidden = true // the film keeps playing (its sound) behind the page

        Haptics.impact(.medium)
        fadeOutAudio(over: Self.curlDuration)
        Task { @MainActor in
            // One frame with the page in place before the curl starts.
            try? await Task.sleep(for: .milliseconds(50))
            UIView.transition(with: self.pageContainer, duration: Self.curlDuration,
                              options: [.transitionCurlUp, .curveEaseInOut],
                              animations: { page.removeFromSuperview() },
                              completion: { _ in
                                  Haptics.impact(.light)
                                  self.finish()
                              })
        }
    }

    /// The frame the film is showing now, from the item's own decoded output.
    private func currentFrame() -> UIImage? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func fadeOutAudio(over duration: TimeInterval) {
        let start = player.volume
        let began = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            while let self, !self.finished {
                let p = min(1, (CACurrentMediaTime() - began) / duration)
                // Equal-power fade: the music leaves smoothly instead of dipping early.
                self.player.volume = start * Float(cos(p * .pi / 2))
                if p >= 1 { self.player.pause(); return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        restoreAudio()
        onFinish()
    }
}

/// A view whose backing layer is the film's AVPlayerLayer, so it resizes with rotation for free.
private final class IntroPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
