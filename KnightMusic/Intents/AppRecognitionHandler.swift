import Foundation

@MainActor
final class AppRecognitionHandler: IntentRecognitionHandling {
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    func startRecognition() {
        guard let app = app ?? AppModel.shared else { return }
        app.startIfNeeded()
        app.startRecognition()
    }
}
