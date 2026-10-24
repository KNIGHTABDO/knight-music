import SwiftUI
import UIKit

/// Shell-level parts of the look: start tab, day/night switching and the shake gesture.
struct LookEffects: ViewModifier {
    let ui: UIState

    @Environment(AppModel.self) private var app
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var appliedStartTab = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: applyStartTab)
            .task {
                // Day/night looks: check now and then once a minute while the app is open.
                while !Task.isCancelled {
                    LookStore.shared.applyScheduleIfNeeded()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { LookStore.shared.applyScheduleIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                handleShake()
            }
    }

    private func applyStartTab() {
        guard !appliedStartTab, app.debugScreen == nil else { return }
        appliedStartTab = true
        switch LookStore.shared.startTab {
        case .home: break
        case .library: ui.selectedTab = sizeClass == .regular ? .section(.albums) : .library
        case .search: ui.selectedTab = .search
        case .knight: ui.selectedTab = .knight
        }
    }

    private func handleShake() {
        switch LookStore.shared.shakeAction {
        case .off:
            return
        case .nextSong:
            guard player.currentSong != nil else { return }
            Haptics.impact(.medium)
            player.next()
        case .surpriseLook:
            LookStore.shared.applySurprise()
            ui.showToast("New look: \(LookStore.shared.current.name)")
        case .shuffleLibrary:
            Haptics.impact(.medium)
            Task {
                let songs = await library.songs(sort: .title).load()
                guard !songs.isEmpty else {
                    ui.showToast("Your library is still empty")
                    return
                }
                player.play(songs, shuffle: true)
                ui.showToast("Shuffling everything")
            }
        }
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("KnightMusic.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
