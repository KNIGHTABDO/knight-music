import SwiftUI
import UIKit

/// iPad: collapses the sidebar in portrait (content gets the full width) and pins it in landscape.
/// Applied only when the orientation changes, so a sidebar the user shows or hides stays that way until the next rotation.
struct SidebarOrientationAdapter: UIViewRepresentable {
    func makeUIView(context: Context) -> OrientationProbe { OrientationProbe() }
    func updateUIView(_ uiView: OrientationProbe, context: Context) {}

    final class OrientationProbe: UIView {
        private var lastLandscape: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        private func apply() {
            guard let window, traitCollection.userInterfaceIdiom == .pad else { return }
            let size = window.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let landscape = size.width > size.height
            guard landscape != lastLandscape,
                  let tabs = Self.tabBarController(in: window.rootViewController) else { return }
            lastLandscape = landscape
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
