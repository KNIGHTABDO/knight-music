import Foundation

/// A lyric line with a stable identity (its line index within the selected lyrics).
struct IdentifiedLyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let line: StructuredLyrics.Line
    /// The line without enhanced-LRC word tags.
    let text: String
    /// Word timings from enhanced LRC (`<mm:ss.xx>word`); empty for plain line-synced lyrics.
    let words: [LyricWord]

    var start: Int? { line.start }

    init(id: Int, line: StructuredLyrics.Line) {
        self.id = id
        self.line = line
        let parsed = LyricsTimeline.parseWords(line.value, lineStart: line.start ?? 0)
        self.text = parsed.text
        self.words = parsed.words
    }
}

/// One sung word with its start time in raw lyric milliseconds (before any offset).
struct LyricWord: Hashable, Sendable {
    let start: Int
    let text: String
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

    /// Splits an enhanced-LRC line (`<00:12.34>Hello <00:12.80>world`) into timed words.
    /// Text before the first tag belongs to the line start.
    nonisolated static func parseWords(_ value: String, lineStart: Int) -> (text: String, words: [LyricWord]) {
        guard value.contains("<") else { return (value, []) }
        let tag = #/<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>/#
        let matches = value.matches(of: tag)
        guard !matches.isEmpty else { return (value, []) }

        var words: [LyricWord] = []
        var plain = ""
        var segmentStart = lineStart
        var cursor = value.startIndex
        for match in matches {
            let segment = String(value[cursor..<match.range.lowerBound])
            if !segment.isEmpty {
                words.append(LyricWord(start: segmentStart, text: segment))
                plain += segment
            }
            let minutes = Int(match.output.1) ?? 0
            let seconds = Int(match.output.2) ?? 0
            var millis = 0
            if let fraction = match.output.3 {
                // ".5" = 500 ms, ".34" = 340 ms, ".345" = 345 ms
                let padded = String(fraction).padding(toLength: 3, withPad: "0", startingAt: 0)
                millis = Int(padded) ?? 0
            }
            segmentStart = (minutes * 60 + seconds) * 1000 + millis
            cursor = match.range.upperBound
        }
        let tail = String(value[cursor...])
        if !tail.isEmpty {
            words.append(LyricWord(start: segmentStart, text: tail))
            plain += tail
        }
        let text = plain.trimmingCharacters(in: .whitespaces)
        return (text, words.count > 1 ? words : [])
    }
}
