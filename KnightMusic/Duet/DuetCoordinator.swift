import SwiftUI
import UIKit
import WebKit

/// Switches Duet between Knight Music and Streamora. Knight Music keeps its own window; Streamora lives in a
/// second window above it and is shown or hidden, so neither side ever loses its state. A glass prompt asks
/// before switching (shake again or tap Switch), and the switch itself is a page curl between the two windows.
@MainActor @Observable
final class DuetCoordinator {
    static let shared = DuetCoordinator()

    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let target: DuetWorld
        let title: String
        let detail: String
    }

    private(set) var world: DuetWorld = .music
    private(set) var prompt: Prompt?
    private(set) var isSwitching = false
    private(set) var hasStage = false
    /// The prompt's frame in the HUD window, so taps on it are caught and everything else falls through.
    @ObservationIgnored var promptFrame: CGRect = .null

    /// How long the prompt waits for a second shake or a tap.
    static let promptDuration: TimeInterval = 4

    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var stageWindow: UIWindow?
    @ObservationIgnored private var hudWindow: DuetHUDWindow?
    @ObservationIgnored private var stageController: StreamoraStageController?
    @ObservationIgnored private var pending: DuetWorld?
    @ObservationIgnored private var restoredLastSide = false
    @ObservationIgnored private var lastShake = Date.distantPast
    @ObservationIgnored private var promptTask: Task<Void, Never>?

    private var settings: DuetSettings { DuetSettings.shared }

    /// Status bar for the window on top: Streamora hides it while a movie plays full screen.
    var statusBarHidden: Bool { world == .movies && (stageController?.statusBarHidden ?? false) }

    /// True when a shake belongs to Duet rather than the "Shake to" action in Customize.
    var wantsShake: Bool { world == .movies || prompt != nil || LookStore.shared.shakeAction == .switchWorld }

    // MARK: - scene

    /// Called by RootView when it appears and whenever the scene becomes active.
    func attach() {
        guard let scene = currentScene() else { return }
        self.scene = scene
        if let target = pending {
            pending = nil
            restoredLastSide = true
            switchTo(target, animated: false)
        } else if !restoredLastSide {
            restoredLastSide = true
            if !DebugLaunch.isDemo, settings.reopenLastSide, settings.lastWorld == .movies {
                switchTo(.movies, animated: false)
            }
        }
    }

    private func currentScene() -> UIWindowScene? {
        if let scene, scene.activationState != .unattached { return scene }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    private func musicWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first { $0 !== stageWindow && !($0 is DuetHUDWindow) && $0.windowLevel == .normal && $0.rootViewController != nil }
    }

    private func ensureStage(in scene: UIWindowScene) -> (UIWindow, StreamoraStageController) {
        if let stageWindow, let stageController, stageWindow.windowScene === scene { return (stageWindow, stageController) }
        let controller = stageController ?? StreamoraStageController()
        stageWindow?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        window.rootViewController = controller
        window.isHidden = true
        stageWindow = window
        stageController = controller
        hasStage = true
        return (window, controller)
    }

    private func ensureHUD(in scene: UIWindowScene) -> DuetHUDWindow {
        if let hudWindow, hudWindow.windowScene === scene { return hudWindow }
        let window = DuetHUDWindow(windowScene: scene)
        window.windowLevel = .normal + 2
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .clear
        let host = DuetHUDHostingController(rootView: DuetHUDView())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        hudWindow = window
        return window
    }

    private func updateHUDVisibility() {
        hudWindow?.isHidden = prompt == nil && !isSwitching
        hudWindow?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - requests

    func handleShake() {
        let now = Date()
        guard now.timeIntervalSince(lastShake) > 0.7 else { return }
        lastShake = now
        guard !isSwitching else { return }
        if let prompt {
            switchTo(prompt.target)
        } else {
            request(world.other)
        }
    }

    /// Asks first when "Ask Before Switching" is on (or `confirm` says so), otherwise switches straight away.
    func request(_ target: DuetWorld, confirm: Bool? = nil) {
        guard target != world, !isSwitching else { return }
        if confirm ?? settings.confirmSwitch {
            showPrompt(for: target)
        } else {
            switchTo(target)
        }
    }

    /// Shortcuts, quick actions and intents: go to a side without asking.
    func open(_ target: DuetWorld) {
        guard currentScene() != nil, restoredLastSide else {
            pending = target
            return
        }
        switchTo(target, animated: UIApplication.shared.applicationState == .active)
    }

    func toggle() { open(pending.map(\.other) ?? world.other) }

    /// After the Duet film: show once where the other side is, with the same pill a shake brings up.
    func teachShake() {
        guard !isSwitching, prompt == nil, LookStore.shared.shakeAction == .switchWorld else { return }
        let target = world.other
        showPrompt(for: target, title: target == .movies ? "Shake for Streamora" : "Shake for Knight Music",
                   detail: target == .movies ? "Movies live on the other side of Duet" : "Your music lives on the other side of Duet")
    }

    private func showPrompt(for target: DuetWorld, title: String? = nil, detail: String? = nil) {
        guard let scene = currentScene() else { return }
        if target == .movies { ensureStage(in: scene).1.loadIfNeeded() }
        let hud = ensureHUD(in: scene)
        let next = Prompt(target: target, title: title ?? (target == .movies ? "Switch to Streamora?" : "Back to Knight Music?"),
                          detail: detail ?? promptDetail(for: target))
        withAnimation(.snappy) { prompt = next }
        hud.isHidden = false
        Haptics.impact(.light)
        promptTask?.cancel()
        guard !DebugLaunch.isDemo else { return }
        promptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.promptDuration))
            guard !Task.isCancelled, let self, self.prompt?.id == next.id else { return }
            self.dismissPrompt()
        }
    }

    private func promptDetail(for target: DuetWorld) -> String {
        let media = DuetMedia.shared
        if target == .movies {
            if AppModel.shared?.player.isPlaying == true {
                return settings.intermission ? "Music plays until a movie starts, then waits for you" : "Music plays until a movie starts"
            }
            return "Shake again or tap Switch"
        }
        if stageController?.bridge.isMoviePlaying == true || media.hasMovie {
            if let song = media.interruptedSongTitle { return "Pauses the movie and resumes “\(song)”" }
            return "Pauses the movie, it waits right here"
        }
        return "Shake again or tap Switch"
    }

    func dismissPrompt() {
        promptTask?.cancel()
        promptTask = nil
        guard prompt != nil else { return }
        withAnimation(.snappy) { prompt = nil }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.updateHUDVisibility()
        }
    }

    // MARK: - switching

    func switchTo(_ target: DuetWorld, animated: Bool = true) {
        promptTask?.cancel()
        promptTask = nil
        if prompt != nil { withAnimation(.snappy) { prompt = nil } }
        guard target != world, !isSwitching else { return updateHUDVisibility() }
        guard let scene = currentScene(), let music = musicWindow(in: scene) else {
            pending = target
            return
        }
        let (stage, controller) = ensureStage(in: scene)
        if target == .movies { controller.loadIfNeeded() } else { DuetMedia.shared.musicTakesFocus() }
        world = target
        if !DebugLaunch.isDemo { settings.lastWorld = target }

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard animated, scene.activationState == .foregroundActive else {
            show(target, stage: stage, music: music)
            updateHUDVisibility()
            return
        }

        isSwitching = true
        let hud = ensureHUD(in: scene)
        hud.isHidden = false
        let container = UIView(frame: hud.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = .clear
        hud.addSubview(container)
        Haptics.impact(.medium)

        let done: () -> Void = { [weak self] in
            container.removeFromSuperview()
            self?.isSwitching = false
            self?.updateHUDVisibility()
            Haptics.impact(.light)
        }

        if target == .movies {
            // Curl Knight Music away to uncover the live Streamora window underneath.
            guard let page = music.snapshotView(afterScreenUpdates: false) else {
                show(target, stage: stage, music: music)
                return done()
            }
            page.frame = container.bounds
            container.addSubview(page)
            show(target, stage: stage, music: music)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                UIView.transition(with: container, duration: reduceMotion ? 0.35 : 0.85,
                                  options: [reduceMotion ? .transitionCrossDissolve : .transitionCurlUp, .curveEaseInOut],
                                  animations: { page.removeFromSuperview() },
                                  completion: { _ in done() })
            }
        } else {
            // Curl Knight Music back down over Streamora, then put Streamora away.
            guard let page = music.snapshotView(afterScreenUpdates: true) else {
                show(target, stage: stage, music: music)
                return done()
            }
            page.frame = container.bounds
            UIView.transition(with: container, duration: reduceMotion ? 0.35 : 0.8,
                              options: [reduceMotion ? .transitionCrossDissolve : .transitionCurlDown, .curveEaseInOut],
                              animations: { container.addSubview(page) },
                              completion: { [weak self] _ in
                                  self?.show(target, stage: stage, music: music)
                                  done()
                              })
        }
    }

    private func show(_ target: DuetWorld, stage: UIWindow, music: UIWindow) {
        if target == .movies {
            stage.isHidden = false
            stage.makeKey()
        } else {
            stage.isHidden = true
            music.makeKey()
        }
        hudWindow?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - settings actions

    func reloadStreamora() { stageController?.reload() }

    /// Signs Streamora out on this device (its data is in Google Drive, so nothing is lost there).
    func clearStreamoraData() async {
        if let stageController {
            await stageController.clearWebsiteData()
        } else {
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                          modifiedSince: .distantPast)
        }
    }
}

