import AppIntents
import Foundation
#if canImport(ShazamKit)
import ShazamKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
public protocol IntentPlaybackHandling: AnyObject {
    func playPause()
    func nextTrack()
    func previousTrack()
    func shuffleLibrary() async
    func playFavorites() async
    func playFavorites(startingAt songId: String) async
}

public enum IntentPlaybackBridge {
    @MainActor public static var handler: IntentPlaybackHandling?
}

public struct PlayPauseIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play/Pause"
    public static var description = IntentDescription("Toggles playback in Knight Music.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentPlaybackBridge.handler?.playPause()
        return .result()
    }
}

public struct NextTrackIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Next Track"
    public static var description = IntentDescription("Plays the next track in Knight Music.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentPlaybackBridge.handler?.nextTrack()
        return .result()
    }
}

public struct PreviousTrackIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Previous Track"
    public static var description = IntentDescription("Plays the previous track in Knight Music.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentPlaybackBridge.handler?.previousTrack()
        return .result()
    }
}

public struct ShuffleLibraryIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Shuffle Library"
    public static var description = IntentDescription("Shuffles your library in Knight Music.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await IntentPlaybackBridge.handler?.shuffleLibrary()
        return .result()
    }
}

public struct PlayFavoritesIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Favorites"
    public static var description = IntentDescription("Plays your favorite songs in Knight Music.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await IntentPlaybackBridge.handler?.playFavorites()
        return .result()
    }
}

public struct PlayFavoriteSongIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Favorite Song"
    public static var description = IntentDescription("Plays your favorite songs in Knight Music, starting with this one.")
    public static var openAppWhenRun: Bool = false
    public static var isDiscoverable: Bool = false

    @Parameter(title: "Song ID")
    public var songId: String

    public init() {}

    public init(songId: String) {
        self.songId = songId
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        await IntentPlaybackBridge.handler?.playFavorites(startingAt: songId)
        return .result()
    }
}

@MainActor
public protocol IntentRecognitionHandling: AnyObject {
    func startRecognition()
}

public enum IntentRecognitionBridge {
    @MainActor public static var handler: IntentRecognitionHandling?
}

public struct RecognizeMusicIntent: AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Recognize Music"
    public static var description = IntentDescription("Identifies music playing around you using Knight Music.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        // Also inform in-app handler if the main app is running
        IntentRecognitionBridge.handler?.startRecognition()

        // Start Live Activity immediately on tap
        RecognitionActivityManager.shared.startListening()

        #if canImport(ShazamKit)
        if #available(iOS 17.0, *) {
            #if canImport(AVFoundation)
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try? audioSession.setActive(true)
            #endif

            do {
                let session = SHManagedSession()
                await session.prepare()

                var hasMatched = false
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if !Task.isCancelled && !hasMatched {
                        session.cancel()
                    }
                }

                for await result in session.results {
                    switch result {
                    case .match(let match):
                        hasMatched = true
                        timeoutTask.cancel()
                        session.cancel()

                        if let item = match.mediaItems.first {
                            let title = item.title ?? "Unknown Title"
                            let artist = item.artist ?? "Unknown Artist"
                            let track = RecognizedTrack(
                                id: item.shazamID ?? UUID().uuidString,
                                title: title,
                                artist: artist,
                                album: item.subtitle,
                                artworkURL: item.artworkURL,
                                appleMusicURL: item.appleMusicURL,
                                isrc: item.isrc
                            )
                            RecognizedTracksStore.shared.add(track)

                            await RecognitionActivityManager.shared.updateMatched(
                                title: title,
                                artist: artist,
                                artworkURL: item.artworkURL,
                                localSongId: nil
                            )
                        } else {
                            await RecognitionActivityManager.shared.updateNotFound()
                        }
                        return .result()

                    case .noMatch:
                        // Window buffer did not match; continue listening until 20s timeout
                        continue

                    case .error(let error, _):
                        let nsError = error as NSError
                        if nsError.domain == "com.apple.ShazamKit" && nsError.code == 202 {
                            // 202 = matchAttemptFailed (audio window didn't yield a match yet); continue listening!
                            continue
                        } else {
                            hasMatched = true
                            timeoutTask.cancel()
                            session.cancel()
                            await RecognitionActivityManager.shared.updateError("Recognition failed: \(error.localizedDescription)")
                            return .result()
                        }

                    @unknown default:
                        continue
                    }
                }

                timeoutTask.cancel()
                if !hasMatched {
                    await RecognitionActivityManager.shared.updateNotFound()
                }
            } catch {
                await RecognitionActivityManager.shared.updateError("Capture error: \(error.localizedDescription)")
            }
        } else {
            await RecognitionActivityManager.shared.updateError("Requires iOS 17+")
        }
        #else
        await RecognitionActivityManager.shared.updateError("ShazamKit not supported")
        #endif

        return .result()
    }
}
