"""Exercise production queue matching and playback handoff on a Linux Swift toolchain."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PLAYBACK = ROOT / "KnightMusic/Core/Playback"

FIXTURE = r'''
import Foundation

struct Song: Codable, Sendable {
    var title: String
    var isYouTube = false
}
enum RepeatMode: String, Codable, Sendable { case off }
struct QueueEntry {
    var id = UUID()
    let song: Song
}
enum SourceKind { case streaming }
struct ResolvedSource { let kind: SourceKind = .streaming }
final class PreparedItem {
    let entry: QueueEntry
    let resolved = ResolvedSource()
    init(_ song: Song) { entry = QueueEntry(song: song) }
}
struct TestServices {
    var reresolveAddress: (() async -> URL?)?
    let currentBaseURL: (() -> URL?)? = { URL(string: "http://127.0.0.1:4533") }
    let networkChangeCount: (() -> Int)? = nil
}
struct PlaybackLog {
    static let logger = PlaybackLog()
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}
@MainActor final class AppModel {
    static let shared: AppModel? = AppModel()
    var accountActivation = 0
}
actor ResolverGate {
    private var hasEntered = false
    private var entered: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func resolve() async -> URL? {
        await withCheckedContinuation { continuation in
            waiting = continuation
            hasEntered = true
            entered?.resume()
            entered = nil
        }
        return URL(string: "http://127.0.0.1:4533")
    }

    func waitUntilCalled() async {
        if !hasEntered { await withCheckedContinuation { entered = $0 } }
    }

    func unblock() {
        waiting?.resume()
        waiting = nil
    }
}

@MainActor final class PlayerEngine {
    var tracked: PreparedItem?
    var streamRetryHistory: [UUID: [TimeInterval]] = [:]
    var userWantsPlaying = true
    var seekTarget: TimeInterval?
    var services = TestServices()
    var trackedNetworkChangeCount = 0
    var trackedBaseURL: URL?
    private(set) var activation: (title: String, autoplay: Bool, time: TimeInterval)?

    func elapsedNow() -> TimeInterval { 30 }
    func resolve(_ song: Song) -> ResolvedSource? { ResolvedSource() }
    func checkNextPreparedAddress() {}
    func activate(entry: QueueEntry, resolved: ResolvedSource, autoplay: Bool, startAt: TimeInterval) {
        activation = (entry.song.title, autoplay, startAt)
    }
'''

RUNNER = r'''
}

@main struct PlaybackProbe {
    @MainActor static func main() async {
        let revision = UUID(), first = UUID(), duplicate = UUID()
        let song = Song(title: "The same song")
        let queue = SavedQueue(songs: [song, song], repeatMode: .off, shuffle: false,
                               revision: revision, entryIDs: [first, duplicate])
        let position = SavedPosition(currentIndex: 0, position: 123, savedAt: Date(),
                                     queueRevision: revision, entryID: duplicate)
        precondition(queue.positionIndex(position) == 1)
        var replacement = queue
        replacement.revision = UUID()
        precondition(replacement.positionIndex(position) == nil)

        for scenario in ["skip", "clear", "change account", "pause and seek"] {
            let engine = PlayerEngine()
            let startingItem = PreparedItem(Song(title: "A"))
            engine.tracked = startingItem
            let resolver = ResolverGate()
            engine.services.reresolveAddress = { await resolver.resolve() }
            let retry = Task { await engine.retryCurrentStreamAfterHandoff(for: startingItem, reason: "fixture") }
            await resolver.waitUntilCalled()
            engine.userWantsPlaying = false
            if scenario == "skip" { engine.tracked = PreparedItem(Song(title: "B")) }
            if scenario == "clear" { engine.tracked = nil }
            if scenario == "change account" { AppModel.shared?.accountActivation += 1 }
            if scenario == "pause and seek" { engine.seekTarget = 78 }
            await resolver.unblock()
            let recovered = await retry.value
            if scenario == "pause and seek" {
                precondition(recovered && engine.activation?.title == "A")
                precondition(engine.activation?.autoplay == false && engine.activation?.time == 78)
            } else {
                precondition(!recovered && engine.activation == nil)
            }
        }
        print("Queue revision, duplicate entries and four delayed playback handoffs passed")
    }
}
'''


def main():
    source = (PLAYBACK / "PlayerEngine+Playback.swift").read_text()
    start = source.index("    func retryCurrentStreamAfterHandoff(")
    end = source.index("    func handleFailure(", start)
    with tempfile.TemporaryDirectory(prefix="duet-playback-check-") as folder:
        fixture = Path(folder) / "PlaybackProbe.swift"
        binary = Path(folder) / "playback-probe"
        fixture.write_text(FIXTURE + source[start:end] + RUNNER)
        subprocess.run(
            ["swiftc", "-parse-as-library", str(PLAYBACK / "PlayQueueStore.swift"), str(fixture), "-o", str(binary)],
            check=True,
            timeout=120,
        )
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
