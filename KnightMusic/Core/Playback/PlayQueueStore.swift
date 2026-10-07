import Foundation

struct QueueSignature: Equatable, Sendable {
    let count: Int
    let orderHash: Int
    let originalOrderHash: Int
    let repeatMode: RepeatMode
    let shuffle: Bool

    static let empty = QueueSignature(
        count: 0,
        orderHash: 0,
        originalOrderHash: 0,
        repeatMode: .off,
        shuffle: false
    )
}

/// Local persistence of the play queue (large, written on change) and playback position (small, written often).
struct SavedQueue: Codable, Sendable {
    var songs: [Song]
    /// Positions (into `songs`) in the original, un-shuffled order. Nil when not shuffled.
    var originalOrder: [Int]?
    var repeatMode: RepeatMode
    var shuffle: Bool
}

struct SavedPosition: Codable, Sendable {
    var currentIndex: Int
    var position: TimeInterval
    var savedAt: Date
}

final class PlayQueueStore: @unchecked Sendable {
    private let queueURL: URL
    private let positionURL: URL
    private let ioQueue = DispatchQueue(label: "com.knightabdo.knightmusic.queuestore", qos: .utility)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        queueURL = base.appendingPathComponent("PlayQueue.json")
        positionURL = base.appendingPathComponent("PlayPosition.json")
    }

    func save(_ queue: SavedQueue?, synchronous: Bool = false) {
        write(queue, to: queueURL, synchronous: synchronous)
    }

    func save(_ position: SavedPosition, synchronous: Bool = false) {
        write(position, to: positionURL, synchronous: synchronous)
    }

    func loadQueue() -> SavedQueue? {
        ioQueue.sync { read(SavedQueue.self, from: queueURL) }
    }

    func loadPosition() -> SavedPosition? {
        ioQueue.sync { read(SavedPosition.self, from: positionURL) }
    }

    private func write<T: Encodable & Sendable>(_ value: T?, to url: URL, synchronous: Bool = false) {
        let work: @Sendable () -> Void = {
            let data: Data?
            if let value {
                do {
                    data = try JSONEncoder().encode(value)
                } catch {
                    PlaybackLog.logger.error("Queue encode failed: \(error.localizedDescription)")
                    return
                }
            } else {
                data = nil
            }
            if let data {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    PlaybackLog.logger.error("Queue write failed: \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if synchronous {
            ioQueue.sync(execute: work)
        } else {
            ioQueue.async(execute: work)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            PlaybackLog.logger.error("Queue decode failed: \(error.localizedDescription)")
            return nil
        }
    }
}
