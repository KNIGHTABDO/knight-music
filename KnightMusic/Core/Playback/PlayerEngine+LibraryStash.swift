import Foundation

/// The library queue that was playing when the user switched to YouTube songs, so it can be picked up again.
struct StashedQueue {
    let order: [QueueEntry]
    let originalOrder: [QueueEntry]
    let index: Int
    let time: TimeInterval
    let shuffle: Bool

    var currentSong: Song? { order.indices.contains(index) ? order[index].song : nil }
    var remainingCount: Int { max(order.count - index, 0) }
}

extension PlayerEngine {
    /// Called before a new queue replaces the current one.
    func stashLibraryQueue(replacingWith songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard songs.allSatisfy(\.isYouTube) else {
            stashedLibraryQueue = nil
            return
        }
        guard currentRadio == nil, order.indices.contains(currentIndex), !order[currentIndex].song.isYouTube else { return }
        stashedLibraryQueue = StashedQueue(order: order, originalOrder: originalOrder, index: currentIndex,
                                           time: currentTime, shuffle: shuffleEnabled)
    }

    func resumeStashedLibraryQueue() {
        guard let stash = stashedLibraryQueue, stash.order.indices.contains(stash.index) else {
            stashedLibraryQueue = nil
            return
        }
        stashedLibraryQueue = nil
        endStation()
        currentRadio = nil
        failedEntryIds = []
        retriedFromStream = []
        consecutiveFailures = 0
        shuffleEnabled = stash.shuffle
        originalOrder = stash.originalOrder
        order = stash.order
        currentIndex = stash.index
        userWantsPlaying = true
        audioSession.activate()
        load(index: currentIndex, autoplay: true, startAt: stash.time)
        saveQueueNow()
    }
}
