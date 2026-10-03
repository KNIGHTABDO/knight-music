import Foundation
import SwiftUI

// Queue editing. Index parameters named `at`/`from`/`to`/`offset` are relative to `upcoming`
// (0 = the song right after the current one) unless stated otherwise.
extension PlayerEngine {
    func enqueue(_ songs: [Song], next: Bool = false) {
        guard !songs.isEmpty else { return }
        guard !order.isEmpty, currentRadio == nil else {
            play(songs)
            return
        }
        let entries = songs.map(QueueEntry.init)
        let at = next ? min(currentIndex + 1, order.count) : order.count
        order.insert(contentsOf: entries, at: at)
        if shuffleEnabled {
            if next, let cur = currentEntry, let oi = originalOrder.firstIndex(where: { $0.id == cur.id }) {
                originalOrder.insert(contentsOf: entries, at: oi + 1)
            } else {
                originalOrder.append(contentsOf: entries)
            }
        }
        queueMutated()
    }

    func move(from source: Int, to destination: Int) {
        move(fromOffsets: IndexSet(integer: source), toOffset: destination > source ? destination + 1 : destination)
    }

    /// `List.onMove` compatible.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard currentRadio == nil, currentIndex + 1 < order.count else { return }
        var tail = Array(order[(currentIndex + 1)...])
        guard source.allSatisfy({ tail.indices.contains($0) }) else { return }
        tail.move(fromOffsets: source, toOffset: min(max(destination, 0), tail.count))
        order = Array(order[...currentIndex]) + tail
        queueMutated()
    }

    func remove(at offset: Int) {
        let index = currentIndex + 1 + offset
        guard offset >= 0, order.indices.contains(index) else { return }
        let removed = order.remove(at: index)
        originalOrder.removeAll { $0.id == removed.id }
        queueMutated()
    }

    func remove(entryId: UUID) {
        guard let index = order.firstIndex(where: { $0.id == entryId }), index != currentIndex else { return }
        order.remove(at: index)
        originalOrder.removeAll { $0.id == entryId }
        if index < currentIndex { currentIndex -= 1 }
        queueMutated()
    }

    func clearUpcoming() {
        guard currentIndex + 1 < order.count else { return }
        order.removeSubrange((currentIndex + 1)...)
        let keep = Set(order.map(\.id))
        originalOrder.removeAll { !keep.contains($0.id) }
        queueMutated()
    }

    /// Jump to an absolute index of `order`.
    func skip(to index: Int) {
        guard order.indices.contains(index), currentRadio == nil else { return }
        userWantsPlaying = true
        audioSession.activate()
        if index == currentIndex {
            seek(to: 0)
            resume()
        } else {
            load(index: index, autoplay: true)
        }
    }

    /// Jump to an entry of `upcoming`.
    func skip(toUpcomingOffset offset: Int) {
        skip(to: currentIndex + 1 + offset)
    }

    func toggleShuffle() { setShuffle(!shuffleEnabled) }

    func setShuffle(_ on: Bool) {
        guard on != shuffleEnabled, currentRadio == nil, !order.isEmpty else {
            if currentRadio == nil, order.isEmpty { shuffleEnabled = on }
            return
        }
        let currentId = currentEntry?.id
        if on {
            originalOrder = order
            let head = Array(order[...currentIndex])
            let tail = Array(order[(currentIndex + 1)...]).shuffled()
            order = head + tail
            shuffleEnabled = true
        } else {
            let present = Set(order.map(\.id))
            var restored = originalOrder.filter { present.contains($0.id) }
            let known = Set(restored.map(\.id))
            restored += order.filter { !known.contains($0.id) }
            order = restored
            shuffleEnabled = false
        }
        if let currentId, let i = order.firstIndex(where: { $0.id == currentId }) { currentIndex = i }
        queueMutated()
    }

    func queueMutated() {
        if let t = tracked, let i = order.firstIndex(where: { $0.id == t.entry.id }) { currentIndex = i }
        prepareNext()
        syncCache()
        nowPlaying.updateQueue(index: currentIndex, count: order.count)
        remote?.refresh()
        saveQueueSoon()
    }
}
