import SwiftUI
import AVFoundation

/// Muted, looping, aspect-fill video. Fades in over whatever is behind it once the first frame is ready.
/// Never touches the audio session (muted, video-only, no external playback) and never blocks display sleep.
/// Pauses while off-screen, while the app is backgrounded, and under Reduce Motion.
struct AnimatedArtworkView: View {
    var url: URL

    @State private var isOnScreen = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingVideoRepresentable(url: url, isActive: isOnScreen && scenePhase == .active && !reduceMotion)
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Static artwork that upgrades to the animated version when the service has one for the song.
struct HeroArtworkView: View {
    var song: Song
    var pointSize: CGFloat = 320
    var cornerRadius: CGFloat = Theme.Radius.large
    /// Prefer the 3:4 video (fills a tall container such as the iPhone player background).
    var prefersTall: Bool = false

    @Environment(AnimatedArtworkService.self) private var service: AnimatedArtworkService?
    @State private var animated: AnimatedArtwork?

    var body: some View {
        ZStack {
            ArtworkView(coverArt: song.coverArt, pointSize: pointSize, cornerRadius: cornerRadius, fillsContainer: true)
            if let animated {
                AnimatedArtworkView(url: prefersTall ? (animated.tallVideoURL ?? animated.squareVideoURL) : animated.squareVideoURL)
                    .id(animated)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: song.id) {
            animated = nil
            animated = await service?.animatedArtwork(for: song)
        }
    }
}

private struct LoopingVideoRepresentable: UIViewRepresentable {
    var url: URL
    var isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.alpha = 0
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view, url: url)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if context.coordinator.url != url { context.coordinator.attach(to: view, url: url) }
        context.coordinator.setActive(isActive)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.teardown(view)
    }

    final class Coordinator {
        var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var readyObservation: NSKeyValueObservation?

        func attach(to view: PlayerLayerView, url: URL) {
            teardown(view)
            self.url = url
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.volume = 0
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: item)
            view.playerLayer.player = player
            self.player = player
            view.alpha = 0
            readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak view] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) { view?.alpha = 1 }
                }
            }
        }

        func setActive(_ active: Bool) {
            guard let player else { return }
            if active { if player.timeControlStatus == .paused { player.play() } } else { player.pause() }
        }

        func teardown(_ view: PlayerLayerView) {
            readyObservation?.invalidate()
            readyObservation = nil
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            view.playerLayer.player = nil
            url = nil
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
