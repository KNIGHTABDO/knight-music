import Foundation

@main
struct TransferReceiptSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let receipt = TransferReceipt(ownerId: "owner-a", attemptId: "attempt-17", epoch: 9,
                                     songId: "track-1", relativePath: "owner-a/track-1-attempt-17.mp3",
                                     stagedPath: "owner-a/.staging/attempt-17.mp3.partial",
                                     outcome: .staged, bytes: 1234, message: nil, createdAt: Date())
        _ = try TransferReceiptStore.write(receipt, under: root)
        let ownerReceipts = try TransferReceiptStore.readAll(ownerId: "owner-a", under: root)
        precondition(ownerReceipts.count == 1)
        precondition(ownerReceipts[0].attemptId == "attempt-17")
        precondition(ownerReceipts[0].epoch == 9)
        precondition(ownerReceipts[0].stagedPath == receipt.stagedPath)
        let otherOwnerReceipts = try TransferReceiptStore.readAll(ownerId: "owner-b", under: root)
        precondition(otherOwnerReceipts.isEmpty)

        let identity = TransferTaskIdentity(ownerId: "owner-a", epoch: 9, attemptId: "attempt-17",
                                            songId: "track-1", relativePath: receipt.relativePath)
        precondition(TransferTaskIdentity(taskDescription: identity.taskDescription) == identity)
        let replacement = TransferTaskIdentity(ownerId: "owner-a", epoch: 9, attemptId: "attempt-18",
                                               songId: "track-1", relativePath: "owner-a/track-1-attempt-18.mp3")
        precondition(identity != replacement)
        let cancelled = TransferReceipt(ownerId: "owner-a", attemptId: "attempt-17", epoch: 9,
                                       songId: "track-1", relativePath: receipt.relativePath,
                                       stagedPath: nil, outcome: .cancelled, bytes: 0,
                                       message: "Cancelled", createdAt: Date())
        _ = try TransferReceiptStore.write(cancelled, under: root)
        let retained = try TransferReceiptStore.readAll(ownerId: "owner-a", under: root)
        precondition(retained.first?.outcome == .staged)

        TransferReceiptStore.remove(receipt, under: root)
        let clearedReceipts = try TransferReceiptStore.readAll(ownerId: "owner-a", under: root)
        precondition(clearedReceipts.isEmpty)
        print("receipt owner and attempt isolation passed")
    }
}
