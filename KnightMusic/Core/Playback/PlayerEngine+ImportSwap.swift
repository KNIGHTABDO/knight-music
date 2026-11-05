import Foundation

extension PlayerEngine {
    /// After "Add to Navidrome" finishes, upcoming copies of the YouTube song play the library file instead.
    /// The song playing right now is left alone so nothing is interrupted.
    func replaceUpcoming(youTubeSongId: String, with librarySong: Song) {
        guard youTubeSongId != librarySong.id else { return }
        var replaced: [UUID: QueueEntry] = [:]
        for index in order.indices where index != currentIndex && order[index].song.id == youTubeSongId {
            let entry = QueueEntry(song: librarySong)
            replaced[order[index].id] = entry
            order[index] = entry
        }
        guard !replaced.isEmpty else { return }
        originalOrder = originalOrder.map { replaced[$0.id] ?? $0 }
        if let next = nextPrepared, replaced[next.entry.id] != nil { prepareNext() }
        saveQueueNow()
        Log.playback.info("Queue now plays the library copy of \(librarySong.title)")
    }
}
