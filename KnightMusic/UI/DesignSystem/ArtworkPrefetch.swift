import SwiftUI

/// Anything a grid or shelf shows with cover art, so tiles can be prefetched before they scroll in.
protocol CoverArtProviding {
    var coverArtId: String? { get }
}

extension Album: CoverArtProviding { var coverArtId: String? { coverArt } }
extension Song: CoverArtProviding { var coverArtId: String? { coverArt } }
extension Artist: CoverArtProviding { var coverArtId: String? { coverArt } }
extension Playlist: CoverArtProviding { var coverArtId: String? { coverArt } }
extension QueueEntry: CoverArtProviding { var coverArtId: String? { song.coverArt } }

/// Warms Nuke's memory cache for the tiles just past the visible ones.
enum ArtworkPrefetch {
    static let lookahead = 12

    static func ahead<Item>(of index: Int, in items: [Item], pointSize: CGFloat, scale: CGFloat) {
        guard index + 1 < items.count else { return }
        let upper = min(items.count, index + 1 + lookahead)
        let ids = items[(index + 1)..<upper].map { ($0 as? CoverArtProviding)?.coverArtId }
        ArtworkLoader.shared.prefetch(coverArts: ids, pointSize: pointSize, scale: scale)
    }
}
