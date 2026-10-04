import AppIntents
import Foundation

@MainActor
public protocol IntentPlaybackHandling: AnyObject {
    func playPause()
    func nextTrack()
    func previousTrack()
    func shuffleLibrary() async
    func playFavorites() async
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
