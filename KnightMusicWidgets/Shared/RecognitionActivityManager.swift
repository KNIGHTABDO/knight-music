import ActivityKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class RecognitionActivityManager {
    public static let shared = RecognitionActivityManager()

    private var currentActivity: Activity<MusicRecognitionAttributes>?
    private var dismissTask: Task<Void, Never>?
    private let appGroupIdentifier = "group.com.knightabdo.knightmusic"

    private init() {}

    public func startListening() {
        dismissTask?.cancel()
        dismissTask = nil

        // If activity already running, update it to listening state
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
            print("Failed to start MusicRecognition Live Activity: \(error)")
        }
    }

    public func updateMatched(title: String, artist: String, artworkURL: URL?, localSongId: String?) async {
        guard let activity = currentActivity else { return }

        // Download artwork to shared container so WidgetKit can load it synchronously from disk
        var artworkFileName: String? = nil
        if let artworkURL {
            let filename = "shazam_art_\(UUID().uuidString.prefix(8)).jpg"
            if let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
                let fileURL = sharedContainer.appendingPathComponent(filename)
                if let (data, _) = try? await URLSession.shared.data(from: artworkURL) {
                    if (try? data.write(to: fileURL)) != nil {
                        artworkFileName = filename
                    }
                }
            }
        }

        await activity.update(
            ActivityContent(
                state: MusicRecognitionAttributes.ContentState(
                    phase: .matched(
                        title: title,
                        artist: artist,
                        artworkURL: artworkURL?.absoluteString,
                        artworkFileName: artworkFileName,
                        localSongId: localSongId
                    )
                ),
                staleDate: nil
            )
        )

        // Auto-dismiss smoothly after 5 seconds matching native Apple Shazam
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await self.endActivity(cleanupFileName: artworkFileName)
        }
    }

    public func updateNotFound() async {
        guard let activity = currentActivity else { return }

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

    public func updateError(_ message: String) async {
        guard let activity = currentActivity else { return }

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

    public func endActivity(cleanupFileName: String? = nil) async {
        dismissTask?.cancel()
        dismissTask = nil

        if let cleanupFileName,
           let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            let fileURL = sharedContainer.appendingPathComponent(cleanupFileName)
            try? FileManager.default.removeItem(at: fileURL)
        }

        if let activity = currentActivity {
            await activity.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
}
