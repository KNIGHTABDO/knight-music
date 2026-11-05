import AppIntents
import Foundation

public enum QuickActionIntentBridge {
    @MainActor public static var handle: ((String) -> Void)?

    @MainActor static func submit(_ action: String) throws {
        guard let handle else { throw QuickActionIntentError.unavailable }
        handle(action)
    }
}

private enum QuickActionIntentError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Open Knight Music and try again." }
}

public struct LoveCurrentSongIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Love Current Song"
    public static var description = IntentDescription("Loves the library song currently playing in Knight Music.")
    public static var openAppWhenRun: Bool = true
    public init() {}

    @MainActor public func perform() async throws -> some IntentResult {
        try QuickActionIntentBridge.submit("love")
        return .result()
    }
}

public struct RecognizeSongIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Recognize Song"
    public static var description = IntentDescription("Opens Knight Music and starts recognizing the music around you.")
    public static var openAppWhenRun: Bool = true
    public init() {}

    @MainActor public func perform() async throws -> some IntentResult {
        try QuickActionIntentBridge.submit("recognize")
        return .result()
    }
}
