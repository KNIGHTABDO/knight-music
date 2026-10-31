import Foundation

@MainActor
final class AppRecognitionHandler: IntentRecognitionHandling {
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    func recognizeInBackground() async -> Bool {
        guard let app = app ?? AppModel.shared else { return false }
        app.startIfNeeded()
        return await app.shazam.recognizeInBackground()
    }

    func recognizeInForeground() async {
        guard let app = app ?? AppModel.shared else { return }
        app.startIfNeeded()
        NotificationCenter.default.post(name: .showMusicRecognition, object: nil)
        await app.shazam.recognizeInForeground()
    }
}
