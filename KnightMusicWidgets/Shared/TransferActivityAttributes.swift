import ActivityKit
import Foundation

/// Live Activity for a batch of song downloads (lock screen + Dynamic Island). Compiled into the app and the widget.
public struct TransferActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var completed: Int
        public var failed: Int
        public var total: Int
        /// 0…1 across the whole batch, including partial progress of songs in flight.
        public var fraction: Double
        public var currentTitle: String?
        public var currentArtist: String?
        public var isFinished: Bool

        public init(completed: Int, failed: Int, total: Int, fraction: Double,
                    currentTitle: String?, currentArtist: String?, isFinished: Bool) {
            self.completed = completed
            self.failed = failed
            self.total = total
            self.fraction = fraction
            self.currentTitle = currentTitle
            self.currentArtist = currentArtist
            self.isFinished = isFinished
        }

        public var remaining: Int { max(0, total - completed - failed) }

        public var headline: String {
            if isFinished {
                if failed > 0 && completed == 0 { return failed == 1 ? "Download failed" : "\(failed) downloads failed" }
                let songs = completed == 1 ? "1 song" : "\(completed) songs"
                return failed > 0 ? "\(songs) downloaded, \(failed) failed" : "\(songs) downloaded"
            }
            return total == 1 ? "Downloading" : "Downloading \(min(total, completed + failed + 1)) of \(total)"
        }
    }

    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
