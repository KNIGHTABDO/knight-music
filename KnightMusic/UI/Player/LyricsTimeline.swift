import Foundation

/// A lyric line with a stable identity (its line index within the selected lyrics).
struct IdentifiedLyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let line: StructuredLyrics.Line

    var text: String { line.value }
    var start: Int? { line.start }

    init(id: Int, line: StructuredLyrics.Line) {
        self.id = id
        self.line = line
    }
}

/// Pure nonisolated binary search and timeline utilities for lyrics.
enum LyricsTimeline {
    /// Binary search for the active line index given a playback time in ms and a sorted array of line start times in ms.
    /// - Returns: `nil` if the time is before the first timed line, or the index of the active line (last line index if after the end).
    nonisolated static func activeLineIndex(for timeMs: Int, in startTimes: [Int]) -> Int? {
        guard !startTimes.isEmpty else { return nil }
        if timeMs < startTimes[0] { return nil }
        guard let last = startTimes.last, timeMs < last else {
            return startTimes.count - 1
        }

        var low = 0
        var high = startTimes.count - 1
        var result = 0

        while low <= high {
            let mid = low + (high - low) / 2
            if startTimes[mid] <= timeMs {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Parameter and naming overloads for flexibility and test callers.
    nonisolated static func binarySearch(for timeMs: Int, in startTimes: [Int]) -> Int? {
        activeLineIndex(for: timeMs, in: startTimes)
    }

    nonisolated static func activeLineIndex(timeMs: Int, in startTimes: [Int]) -> Int? {
        activeLineIndex(for: timeMs, in: startTimes)
    }

    nonisolated static func activeLineIndex(timeMs: Int, startTimes: [Int]) -> Int? {
        activeLineIndex(for: timeMs, in: startTimes)
    }

    nonisolated static func binarySearch(timeMs: Int, startTimes: [Int]) -> Int? {
        activeLineIndex(for: timeMs, in: startTimes)
    }

    nonisolated static func activeLineIndex(for currentTime: TimeInterval, in startTimes: [Int]) -> Int? {
        activeLineIndex(for: Int(currentTime * 1000), in: startTimes)
    }

    /// Precomputes a sorted array of line start times (ms) adjusted for the effective offset.
    nonisolated static func lineStartTimes(for lyrics: StructuredLyrics, effectiveOffsetMs: Int = 0) -> [Int] {
        var lastStart = 0
        return lyrics.line.map { line in
            let start = line.start ?? lastStart
            lastStart = max(lastStart, start)
            return start - effectiveOffsetMs
        }
    }

    /// Precomputes an array of lines with stable identities.
    nonisolated static func identifiedLines(for lyrics: StructuredLyrics) -> [IdentifiedLyricLine] {
        lyrics.line.enumerated().map { IdentifiedLyricLine(id: $0.offset, line: $0.element) }
    }
}

// MARK: - Free function overloads

nonisolated func activeLineIndex(for timeMs: Int, in startTimes: [Int]) -> Int? {
    LyricsTimeline.activeLineIndex(for: timeMs, in: startTimes)
}

nonisolated func binarySearch(for timeMs: Int, in startTimes: [Int]) -> Int? {
    LyricsTimeline.activeLineIndex(for: timeMs, in: startTimes)
}

nonisolated func activeLineIndex(timeMs: Int, in startTimes: [Int]) -> Int? {
    LyricsTimeline.activeLineIndex(for: timeMs, in: startTimes)
}

nonisolated func activeLineIndex(timeMs: Int, startTimes: [Int]) -> Int? {
    LyricsTimeline.activeLineIndex(for: timeMs, in: startTimes)
}

nonisolated func binarySearch(timeMs: Int, startTimes: [Int]) -> Int? {
    LyricsTimeline.activeLineIndex(for: timeMs, in: startTimes)
}

nonisolated func activeLineIndex(for currentTime: TimeInterval, in startTimes: [Int]) -> Int? {
    LyricsTimeline.activeLineIndex(for: currentTime, in: startTimes)
}
