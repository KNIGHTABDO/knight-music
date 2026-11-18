import AppIntents
import Foundation

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

    /// The app process wires the handler at launch; when it hasn't yet, say so instead of reporting a silent success.
    @MainActor public static func requireHandler() throws -> IntentPlaybackHandling {
        guard let handler else { throw IntentPlaybackError.appNotReady }
        return handler
    }
}

public enum IntentPlaybackError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady

    public var localizedStringResource: LocalizedStringResource {
        "Open Knight Music and sign in first, then try again."
    }
}

public struct PlayPauseIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play/Pause"
    public static var description = IntentDescription("Toggles playback in Knight Music.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try IntentPlaybackBridge.requireHandler().playPause()
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
        try IntentPlaybackBridge.requireHandler().nextTrack()
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
        try IntentPlaybackBridge.requireHandler().previousTrack()
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
        try await IntentPlaybackBridge.requireHandler().shuffleLibrary()
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
        try await IntentPlaybackBridge.requireHandler().playFavorites()
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
        try await IntentPlaybackBridge.requireHandler().playFavorites(startingAt: songId)
        return .result()
    }
}

@MainActor
public protocol IntentRecognitionHandling: AnyObject {
    /// Runs to the end of recognition. false when iOS refused to start from the background.
    func recognizeInBackground() async -> Bool
    func recognizeInForeground() async
}

public enum IntentRecognitionBridge {
    @MainActor public static var handler: IntentRecognitionHandling?
}

public struct RecognizeMusicIntent: AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Recognize Music"
    public static var description = IntentDescription("Identifies music playing around you using Knight Music.")
    /// Stays in the current app when iOS allows the mic to start there, and opens Knight Music only when it doesn't.
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let handler = IntentRecognitionBridge.handler else { throw IntentPlaybackError.appNotReady }
        if await handler.recognizeInBackground() { return .result() }
        try await continueInForeground(alwaysConfirm: false)
        await handler.recognizeInForeground()
        return .result()
    }
}
