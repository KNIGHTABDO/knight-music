import Foundation
import ReplayKit
import UserNotifications

/// The only supported way for a third-party app to hear other apps' audio, which the mic can't do on headphones.
/// Runs in its own process, so it finishes the whole job itself while the user stays in the other app.
final class SampleHandler: RPBroadcastSampleHandler {
    private let collector = PCMClipCollector()
    private var recognition: Task<Void, Never>?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard RecognitionCredentials.isSharedStorageAvailable, let credentials = RecognitionCredentials.load() else {
            stop(reason: "Open Knight Music once while signed in, then start listening again.")
            return
        }
        recognition = Task { [collector, weak self] in
            let outcome = await RecognitionLoop.run(collector: collector, credentials: credentials)
            await self?.finish(outcome)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if sampleBufferType == .audioApp { collector.append(sampleBuffer) }
    }

    override func broadcastFinished() {
        recognition?.cancel()
    }

    private func finish(_ outcome: RecognitionOutcome) async {
        switch outcome {
        case .matched(let track):
            await MainActor.run { RecognizedTracksStore.shared.add(track) }
            BroadcastResultMailbox.post(trackID: track.id)
            await notify(track)
            stop(reason: "Found \"\(track.title)\" by \(track.artist). It's saved in Knight Music.")
        case .notFound:
            stop(reason: "No match found for the audio on this device.")
        case .silent:
            stop(reason: "No audio was playing, or the app playing it blocks capture.")
        case .failed(let message):
            stop(reason: message)
        case .cancelled:
            break
        }
    }

    private func notify(_ track: RecognizedTrack) async {
        let content = UNMutableNotificationContent()
        content.title = track.title
        content.body = track.artist
        content.sound = .default
        let request = UNNotificationRequest(identifier: "recognized-\(track.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// ReplayKit's only way to end a broadcast is with an error, whose reason iOS shows to the user.
    private func stop(reason: String) {
        finishBroadcastWithError(NSError(
            domain: "com.knightabdo.knightmusic.broadcast",
            code: 1,
            userInfo: [NSLocalizedFailureReasonErrorKey: reason]
        ))
    }
}
