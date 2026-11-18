import Foundation

/// URLSession delegate. Stages the result and atomically persists its receipt before returning,
/// so recovery never depends on the OS temporary file surviving the callback.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?
    private let directory: URL
    init(directory: URL) {
        self.directory = directory
    }

    static func parse(_ description: String?) -> (ownerId: String, epoch: UInt64, attemptId: String,
                                                  id: String, relativePath: String)? {
        if let identity = TransferTaskIdentity(taskDescription: description) {
            return (identity.ownerId, identity.epoch, identity.attemptId, identity.songId, identity.relativePath)
        }
        guard let description else { return nil }
        let fields = description.split(separator: "|", maxSplits: 3).map(String.init)
        if fields.count == 4 { return (fields[0], 0, fields[1], fields[2], fields[3]) }
        if fields.count == 2 { return ("legacy", 0, "", fields[0], fields[1]) }
        return nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let parsed = Self.parse(downloadTask.taskDescription) else { return }
        let id = parsed.id
        let manager = self.manager
        let owner = parsed.ownerId
        let epoch = parsed.epoch
        let attempt = parsed.attemptId
        Task { @MainActor in
            manager?.progress(id, owner: owner, epoch: epoch, attempt: attempt,
                              received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parsed = Self.parse(downloadTask.taskDescription) else { return }
        let id = parsed.id
        let rel = parsed.relativePath
        var failure: String?
        var failureCode: Int?
        var bytes = 0
        var stagedPath: String?
        let http = downloadTask.response as? HTTPURLResponse
        let mime = http?.mimeType?.lowercased() ?? ""
        if http?.statusCode != 200 {
            failure = "Server returned status \(http?.statusCode ?? 0)"
            failureCode = http?.statusCode
        } else if mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text") {
            // Subsonic reports errors as HTTP 200 with a JSON/XML body.
            failure = "The server returned an error instead of audio"
        } else {
            let ext = (rel as NSString).pathExtension
            let staging = directory.appendingPathComponent(parsed.ownerId, isDirectory: true)
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent("\(parsed.attemptId).partial.\(ext)")
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
                try fm.moveItem(at: location, to: staging)
                excludeFromBackup(staging)
                bytes = (try fm.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.intValue ?? 0
                if bytes == 0 {
                    try? fm.removeItem(at: staging)
                    failure = "The downloaded file was empty"
                } else {
                    stagedPath = String(staging.path.dropFirst(directory.path.count + 1))
                }
            } catch {
                failure = "Couldn\u{2019}t save the file: \(error.localizedDescription)"
                if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteOutOfSpaceError {
                    failure = DownloadManager.storageMessage
                }
            }
        }
        let receipt = TransferReceipt(ownerId: parsed.ownerId, attemptId: parsed.attemptId, epoch: parsed.epoch,
                                      songId: id, relativePath: rel, stagedPath: stagedPath,
                                      outcome: failure == nil ? .staged : .failed, bytes: bytes,
                                      message: failure, createdAt: Date(), errorCode: failureCode)
        deliver(receipt)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let parsed = Self.parse(task.taskDescription) else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        let receipt = TransferReceipt(ownerId: parsed.ownerId, attemptId: parsed.attemptId, epoch: parsed.epoch,
                                      songId: parsed.id, relativePath: parsed.relativePath, stagedPath: nil,
                                      outcome: cancelled ? .cancelled : .failed, bytes: 0,
                                      message: cancelled ? "Cancelled" : error.localizedDescription, createdAt: Date(),
                                      errorCode: (error as NSError).domain == NSURLErrorDomain ? (error as NSError).code : nil)
        deliver(receipt)
    }

    private func deliver(_ receipt: TransferReceipt) {
        let manager = self.manager
        do {
            let durableReceipt = try TransferReceiptStore.write(receipt, under: directory)
            Task { @MainActor in manager?.finished(durableReceipt, epoch: receipt.epoch) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                manager?.receiptWriteFailed(owner: receipt.ownerId, epoch: receipt.epoch, attempt: receipt.attemptId,
                                            songId: receipt.songId, message: message)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        Task { @MainActor in AppDelegate.finishBackgroundEvents(identifier: identifier) }
    }
}
