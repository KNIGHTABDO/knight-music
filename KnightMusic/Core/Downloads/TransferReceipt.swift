import Foundation

struct TransferTaskIdentity: Equatable, Sendable {
    let ownerId: String
    let epoch: UInt64
    let attemptId: String
    let songId: String
    let relativePath: String

    init(ownerId: String, epoch: UInt64, attemptId: String, songId: String, relativePath: String) {
        self.ownerId = ownerId
        self.epoch = epoch
        self.attemptId = attemptId
        self.songId = songId
        self.relativePath = relativePath
    }

    var taskDescription: String { "\(ownerId)|\(epoch)|\(attemptId)|\(songId)|\(relativePath)" }

    init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let fields = taskDescription.split(separator: "|", maxSplits: 4).map(String.init)
        guard fields.count == 5, let epoch = UInt64(fields[1]) else { return nil }
        self.init(ownerId: fields[0], epoch: epoch, attemptId: fields[2], songId: fields[3], relativePath: fields[4])
    }
}

/// Durable callback outcome written on URLSession's delegate queue before iOS may
/// discard the delivered temporary file or finish background event delivery.
struct TransferReceipt: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case staged, failed, cancelled }
    let ownerId: String
    let attemptId: String
    let epoch: UInt64
    let songId: String
    let relativePath: String
    let stagedPath: String?
    let outcome: Outcome
    let bytes: Int
    let message: String?
    let createdAt: Date
}

enum TransferReceiptStore {
    static func write(_ receipt: TransferReceipt, under root: URL) throws -> TransferReceipt {
        let folder = root.appendingPathComponent(".receipts", isDirectory: true)
            .appendingPathComponent(receipt.ownerId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(receipt.attemptId + ".json")
        if let existingData = try? Data(contentsOf: target),
           let existing = try? JSONDecoder().decode(TransferReceipt.self, from: existingData),
           existing.outcome == .staged, receipt.outcome != .staged {
            return existing
        }
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: target, options: .atomic)
        return receipt
    }

    static func readAll(ownerId: String, under root: URL) throws -> [TransferReceipt] {
        let folder = root.appendingPathComponent(".receipts", isDirectory: true)
            .appendingPathComponent(ownerId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(TransferReceipt.self, from: Data(contentsOf: $0)) }
    }

    static func remove(_ receipt: TransferReceipt, under root: URL) {
        let file = root.appendingPathComponent(".receipts", isDirectory: true)
            .appendingPathComponent(receipt.ownerId, isDirectory: true)
            .appendingPathComponent(receipt.attemptId + ".json")
        try? FileManager.default.removeItem(at: file)
    }
}
