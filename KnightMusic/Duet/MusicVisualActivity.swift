import SwiftUI

/// The Music window stays mounted when Movies is on top, so scene phase alone is insufficient.
@propertyWrapper
struct MusicVisualActivity: DynamicProperty {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor var wrappedValue: Bool {
        scenePhase == .active && DuetCoordinator.shared.world == .music && !reduceMotion
    }
}
