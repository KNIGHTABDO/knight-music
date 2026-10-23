import SwiftUI

/// Grid or list presentation for album-style library screens; each screen remembers its own choice.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }
    var title: String { self == .grid ? "Grid" : "List" }
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

/// One album as a list row: 56pt cover, title, artist · year, chevron.
struct AlbumListRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: album.coverArt, pointSize: 56, cornerRadius: 6)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.kmRowTitle)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.kmRowSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if album.starred != nil {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.tertiaryLabel)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Quiet pinned section header for A–Z sections ("A", "B" …) over a black backing.
struct LetterHeader: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 6)
            .background(Theme.background.opacity(0.92))
            .accessibilityAddTraits(.isHeader)
    }
}
