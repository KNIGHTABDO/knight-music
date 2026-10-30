import ActivityKit
import Foundation

@MainActor
public final class RecognitionActivityManager {
    public static let shared = RecognitionActivityManager()

    private var currentActivity: Activity<MusicRecognitionAttributes>?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    public func startListening() {
        dismissTask?.cancel()
        dismissTask = nil

        // If activity already running, update it
        if let activity = currentActivity {
            Task {
                await activity.update(
                    ActivityContent(
                        state: MusicRecognitionAttributes.ContentState(phase: .listening),
                        staleDate: Date().addingTimeInterval(30)
                    )
                )
            }
            return
        }

        // Check if device supports Live Activities
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = MusicRecognitionAttributes()
        let initialContent = ActivityContent(
            state: MusicRecognitionAttributes.ContentState(phase: .listening),
            staleDate: Date().addingTimeInterval(30)
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: initialContent,
                pushType: nil
            )
        } catch {
            Log.app.warning("Failed to start MusicRecognition Live Activity: \(error)")
        }
    }

    public func updateMatched(title: String, artist: String, artworkURL: String?, localSongId: String?) {
        guard let activity = currentActivity else { return }

        Task {
            await activity.update(
                ActivityContent(
                    state: MusicRecognitionAttributes.ContentState(
                        phase: .matched(title: title, artist: artist, artworkURL: artworkURL, localSongId: localSongId)
                    ),
                    staleDate: nil
                )
            )

            // Auto-dismiss smoothly after 5 seconds
            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await self.endActivity()
            }
        }
    }

    public func updateNotFound() {
        guard let activity = currentActivity else { return }

        Task {
            await activity.update(
                ActivityContent(
                    state: MusicRecognitionAttributes.ContentState(phase: .notFound),
                    staleDate: nil
                )
            )

            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await self.endActivity()
            }
        }
    }

    public func updateError(_ message: String) {
        guard let activity = currentActivity else { return }

        Task {
            await activity.update(
                ActivityContent(
                    state: MusicRecognitionAttributes.ContentState(phase: .error(message: message)),
                    staleDate: nil
                )
            )

            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await self.endActivity()
            }
        }
    }

    public func endActivity() async {
        dismissTask?.cancel()
        dismissTask = nil

        if let activity = currentActivity {
            await activity.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
}
