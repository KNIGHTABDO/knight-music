import Foundation

/// Local persistence of the play queue (large, written on change) and playback position (small, written often).
struct SavedQueue: Codable {
    var songs: [Song]
    /// Positions (into `songs`) in the original, un-shuffled order. Nil when not shuffled.
    var originalOrder: [Int]?
    var repeatMode: RepeatMode
    var shuffle: Bool
}

struct SavedPosition: Codable {
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

    func save(_ queue: SavedQueue?) {
        write(queue, to: queueURL)
    }

    func save(_ position: SavedPosition) {
        write(position, to: positionURL)
    }

    func loadQueue() -> SavedQueue? { read(SavedQueue.self, from: queueURL) }
    func loadPosition() -> SavedPosition? { read(SavedPosition.self, from: positionURL) }

    private func write<T: Encodable>(_ value: T?, to url: URL) {
        let data: Data?
        if let value {
            do { data = try JSONEncoder().encode(value) } catch {
                PlaybackLog.logger.error("Queue encode failed: \(error.localizedDescription)")
                return
            }
        } else {
            data = nil
        }
        ioQueue.async {
            if let data {
                do { try data.write(to: url, options: .atomic) } catch {
                    PlaybackLog.logger.error("Queue write failed: \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
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
