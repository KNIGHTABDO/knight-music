import SwiftUI

/// 56pt circular image, 17pt name, optional subtitle and chevron.
struct ArtistRow: View {
    var name: String
    var coverArt: String?
    var subtitle: String?
    var showsChevron: Bool = true

    init(name: String, coverArt: String?, subtitle: String? = nil, showsChevron: Bool = true) {
        self.name = name
        self.coverArt = coverArt
        self.subtitle = subtitle
        self.showsChevron = showsChevron
    }

    init(artist: Artist, showsChevron: Bool = true) {
        self.init(name: artist.name, coverArt: artist.coverArt,
                  subtitle: artist.albumCount.map { KMFormat.albumCount($0) }, showsChevron: showsChevron)
    }

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverArt: coverArt, pointSize: 56, isCircle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.kmRowTitle).foregroundStyle(Theme.label).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.kmRowSubtitle).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 2x2 mosaic of up to 4 covers + name and "67 Songs • 3 hrs, 23 min".
struct PlaylistRow: View {
    var name: String
    var coverArts: [String?]
    var songCount: Int
    var duration: TimeInterval

    var body: some View {
        HStack(spacing: 14) {
            PlaylistMosaic(coverArts: coverArts, side: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.kmRowTitle).foregroundStyle(Theme.label).lineLimit(1)
                Text(KMFormat.songsAndDuration(count: songCount, seconds: duration))
                    .font(.kmRowSubtitle).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.tertiaryLabel)
        }
        .contentShape(Rectangle())
    }
}

struct PlaylistMosaic: View {
    var coverArts: [String?]
    var side: CGFloat

    var body: some View {
        let unique = Array(NSOrderedSet(array: coverArts.compactMap { $0 })) as? [String] ?? []
        Group {
            if unique.count >= 4 {
                let half = side / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) { tile(unique[0], half); tile(unique[1], half) }
                    HStack(spacing: 0) { tile(unique[2], half); tile(unique[3], half) }
                }
            } else {
                ArtworkView(coverArt: unique.first, pointSize: side, cornerRadius: 0, placeholderSymbol: "music.note.list")
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private func tile(_ id: String, _ size: CGFloat) -> some View {
        ArtworkView(coverArt: id, pointSize: size, cornerRadius: 0)
    }
}
