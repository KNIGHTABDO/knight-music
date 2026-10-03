import SwiftUI

/// Horizontal shelf tile for a playlist:
/// Displays a square mosaic/cover (150pt iPhone / 200pt iPad), title and song count.
struct PlaylistTile: View {
    let playlist: Playlist
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let tileWidth: CGFloat = sizeClass == .regular ? 200 : 150
        VStack(alignment: .leading, spacing: 6) {
            PlaylistMosaic(coverArts: [playlist.coverArt], side: tileWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.name)
                    .font(.kmTileTitle)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(KMFormat.songCount(playlist.songCount ?? 0))
                    .font(.kmTileSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
