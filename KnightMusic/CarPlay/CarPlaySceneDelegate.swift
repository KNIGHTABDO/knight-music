import CarPlay
import UIKit

/// CarPlay template scene delegate. Only connects when the build carries `com.apple.developer.carplay-audio`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated {
            guard let app = AppModel.shared else {
                Log.ui.error("CarPlay connected before AppModel exists; nothing to show")
                return
            }
            Log.ui.info("CarPlay connected")
            app.startIfNeeded()
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
            Log.ui.info("CarPlay disconnected")
            self.coordinator?.disconnect()
            self.coordinator = nil
        }
    }
}
