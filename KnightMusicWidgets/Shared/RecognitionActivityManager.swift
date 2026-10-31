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

    private var activeActivity: Activity<MusicRecognitionAttributes>? {
        // An ended activity waiting out its dismissal time ignores updates, so it can't be reused.
        if let currentActivity, currentActivity.activityState == .active { return currentActivity }
        return Activity<MusicRecognitionAttributes>.activities.first { $0.activityState == .active }
    }

    private init() {}

    /// false when no Live Activity could start, which AudioRecordingIntent requires to keep recording.
    @discardableResult
    public func startListening() -> Bool {
        dismissTask?.cancel()
        dismissTask = nil
        removeOldPosters()

        // If activity already running, update it to listening state
        if let activity = activeActivity {
            currentActivity = activity
            Task {
                await activity.update(
                    ActivityContent(
                        state: MusicRecognitionAttributes.ContentState(phase: .listening),
                        staleDate: Date().addingTimeInterval(30)
                    )
                )
            }
            return true
        }

        // Check if device supports Live Activities
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }

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
            return true
        } catch {
            print("Failed to start MusicRecognition Live Activity: \(error)")
            return false
        }
    }

    public func updateMatched(title: String, artist: String, artworkURL: URL?, localSongId: String?) async {
        guard let activity = activeActivity else { return }

        // Download artwork to shared container so WidgetKit can load it synchronously from disk
        var artworkFileName: String? = nil
        if let artworkURL {
            let filename = "shazam_art_\(UUID().uuidString.prefix(8)).jpg"
            if let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
                let fileURL = sharedContainer.appendingPathComponent(filename)
                if let (data, _) = try? await URLSession.shared.data(from: artworkURL), let poster = bannerPoster(from: data) {
                    if (try? poster.write(to: fileURL)) != nil {
                        artworkFileName = filename
                    }
                }
            }
        }

        let content = ActivityContent(
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
        // The alert is what makes iOS drop the banner over the current app; a plain update changes it silently.
        await activity.update(content, alertConfiguration: AlertConfiguration(title: "\(title)", body: "\(artist)", sound: .default))

        // Ending with a later dismissal leaves iOS to remove it, even if the app is suspended by then.
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
            self.currentActivity = nil
        }
    }

    private func bannerPoster(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = CGSize(width: 180, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func removeOldPosters() {
        guard Activity<MusicRecognitionAttributes>.activities.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier),
              let files = try? FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasPrefix("shazam_art_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func updateNotFound() async {
        guard let activity = activeActivity else { return }

        await activity.update(
            ActivityContent(
                state: MusicRecognitionAttributes.ContentState(phase: .notFound),
                staleDate: nil
            ),
            alertConfiguration: AlertConfiguration(title: "No Match Found", body: "Knight Music couldn't identify this song.", sound: .default)
        )

        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self.endActivity()
        }
    }

    public func updateError(_ message: String) async {
        guard let activity = activeActivity else { return }

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

        for activity in Activity<MusicRecognitionAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }
}
