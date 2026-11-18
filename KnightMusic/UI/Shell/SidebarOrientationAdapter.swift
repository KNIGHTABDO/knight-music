import SwiftUI
import UIKit

/// iPad: collapses the sidebar in portrait (content gets the full width) and pins it in landscape.
/// Applied only when the orientation changes, so a sidebar the user shows or hides stays that way until the next rotation.
struct SidebarOrientationAdapter: ViewModifier {
    @State private var isLandscape: Bool?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
            .background(SidebarVisibilityProbe(isLandscape: isLandscape))
    }
}

private struct SidebarVisibilityProbe: UIViewRepresentable {
    var isLandscape: Bool?

    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.isLandscape = isLandscape
    }

    final class ProbeView: UIView {
        private var applied: Bool?

        var isLandscape: Bool? {
            didSet { scheduleApply() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleApply()
        }

        /// After the current layout pass, so the system's own size-change handling of the sidebar has run first.
        private func scheduleApply() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let landscape = isLandscape, landscape != applied,
                  let window, traitCollection.userInterfaceIdiom == .pad,
                  let tabs = Self.tabBarController(in: window.rootViewController) else { return }
            // The tab controller may already be leaving the window (sign-out swaps it for the login screen); animating its
            // sidebar then aborts in UIKit with BUG_IN_CLIENT_OF_TARGETED_PREVIEW__VIEW_IS_NOT_IN_A_WINDOW.
            guard tabs.viewIfLoaded?.window === window, !tabs.isBeingDismissed, !tabs.isMovingFromParent else { return }
            applied = landscape
            guard tabs.sidebar.isHidden != !landscape else { return }
            tabs.sidebar.isHidden = !landscape
        }

        private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let tabs = tabBarController(in: child) { return tabs }
            }
            return nil
        }
    }
}
