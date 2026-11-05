import UIKit

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcut = connectionOptions.shortcutItem { perform(shortcut) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        perform(shortcutItem)
        completionHandler(true)
    }

    private func perform(_ shortcut: UIApplicationShortcutItem) {
        AppActionRouter.shared.submit(shortcut.type.components(separatedBy: ".").last ?? "")
    }
}
