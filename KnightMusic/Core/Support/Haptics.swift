import UIKit

/// Feedback scaled by the user's haptics level (Settings → Customize → Feel).
@MainActor
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        switch LookStore.shared.haptics {
        case .off: return
        case .subtle: UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: 0.5)
        case .normal: UIImpactFeedbackGenerator(style: style).impactOccurred()
        case .strong: UIImpactFeedbackGenerator(style: stronger(style)).impactOccurred(intensity: 1)
        }
    }

    static func selection() {
        guard LookStore.shared.haptics != .off else { return }
        if LookStore.shared.haptics == .strong {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        switch LookStore.shared.haptics {
        case .off: return
        case .subtle: UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        case .normal, .strong: UINotificationFeedbackGenerator().notificationOccurred(type)
        }
    }

    private static func stronger(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch style {
        case .light, .soft: .medium
        case .medium: .heavy
        default: style
        }
    }
}
