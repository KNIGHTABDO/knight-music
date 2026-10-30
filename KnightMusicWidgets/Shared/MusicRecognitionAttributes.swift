import ActivityKit
import Foundation

public struct MusicRecognitionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public enum Phase: Codable, Hashable {
            case listening
            case matched(title: String, artist: String, artworkURL: String?, localSongId: String?)
            case notFound
            case error(message: String)
        }

        public var phase: Phase
        public var timestamp: Date

        public init(phase: Phase, timestamp: Date = Date()) {
            self.phase = phase
            self.timestamp = timestamp
        }
    }

    public var sessionId: String

    public init(sessionId: String = UUID().uuidString) {
        self.sessionId = sessionId
    }
}
