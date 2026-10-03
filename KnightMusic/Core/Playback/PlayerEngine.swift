import Foundation

@MainActor @Observable
final class PlayerEngine {
    private(set) var currentSong: Song?
    private(set) var isPlaying = false
}
