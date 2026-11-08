import UIKit

/// The Duet film: plays once, the first time Duet 1.0 opens, and again from Settings → Duet. It lives in its own
/// window above everything (Knight Music, Streamora and the HUD), so the app underneath is already mounted and
/// the film can hand over to it with a page curl instead of a cut.
@MainActor
final class IntroFilm {
    static let shared = IntroFilm()

    /// Bump when a new film should play again for everyone.
    private static let filmVersion = 1
    private static let seenKey = "intro.filmSeen"

    private var window: UIWindow?

    static var fileURL: URL? { Bundle.main.url(forResource: "duet-intro", withExtension: "mp4") }
    static var isAvailable: Bool { fileURL != nil }

    var isPlaying: Bool { window != nil }

    /// First launch of this film version, in the foreground, with nothing already playing.
    func presentIfDue() {
        guard !DebugLaunch.isDemo, !isPlaying,
              UserDefaults.standard.integer(forKey: Self.seenKey) < Self.filmVersion,
              !UIAccessibility.isReduceMotionEnabled,
              AppModel.shared?.player.isPlaying != true,
              UIApplication.shared.applicationState == .active,
              let scene = activeScene()
        else { return }
        present(in: scene, replay: false)
    }

    /// Settings → Duet → Play the Duet Film.
    func replay() {
        guard !isPlaying, let scene = activeScene() else { return }
        present(in: scene, replay: true)
    }

    private func present(in scene: UIWindowScene, replay: Bool) {
        guard let url = Self.fileURL else {
            Log.app.error("Intro film missing from the bundle")
            return
        }
        UserDefaults.standard.set(Self.filmVersion, forKey: Self.seenKey)
        if replay, AppModel.shared?.player.isPlaying == true { AppModel.shared?.player.togglePlayPause() }

        let window = IntroWindow(windowScene: scene)
        window.windowLevel = .normal + 3
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .clear
        let controller = IntroFilmController(url: url, skipDelay: replay ? 1 : 3) { [weak self] in
            self?.finished(teach: !replay)
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
    }

    private func finished(teach: Bool) {
        window?.isHidden = true
        window = nil
        // Hand key status back to whichever side is showing.
        let windows = activeScene()?.windows ?? []
        windows.last { !$0.isHidden && $0.windowLevel <= .normal + 1 && $0.rootViewController != nil }?.makeKey()
        if teach { DuetCoordinator.shared.teachShake() }
    }

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

/// Keeps the film's controller in charge of the status bar and home indicator while it plays.
private final class IntroWindow: UIWindow {}
