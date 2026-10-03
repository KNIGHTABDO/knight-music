import Foundation

struct AnimatedArtwork: Hashable {
    var squareVideoURL: URL
    var tallVideoURL: URL?
}

@MainActor @Observable
final class AnimatedArtworkService {
    func animatedArtwork(for song: Song) async -> AnimatedArtwork? { nil }
    func nowPlayingEntries(for song: Song) async -> [String: Any] { [:] }
}
