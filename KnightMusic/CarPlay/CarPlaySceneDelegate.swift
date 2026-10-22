import CarPlay
import UIKit

/// CarPlay template scene delegate. Only connects when the build carries `com.apple.developer.carplay-audio`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        AppModel.shared?.startIfNeeded()
        MainActor.assumeIsolated {
            guard let app = AppModel.shared else { return }
            let coord = CarPlayCoordinator(appModel: app, interfaceController: interfaceController)
            self.coordinator = coord
            coord.start()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated {
            self.coordinator?.disconnect()
            self.coordinator = nil
        }
    }
}
