import SwiftUI

/// Square cover, title (15) and subtitle (13 secondary), one line each. Width comes from its container.
struct AlbumTile: View {
    var coverArt: String?
    var title: String
    var subtitle: String?
    var artworkPointSize: CGFloat = 200
    var isCircle: Bool = false

    init(coverArt: String?, title: String, subtitle: String? = nil, artworkPointSize: CGFloat = 200, isCircle: Bool = false) {
        self.coverArt = coverArt
        self.title = title
        self.subtitle = subtitle
        self.artworkPointSize = artworkPointSize
        self.isCircle = isCircle
    }

    init(album: Album, artworkPointSize: CGFloat = 200) {
        self.init(coverArt: album.coverArt, title: album.name, subtitle: album.artist, artworkPointSize: artworkPointSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(coverArt: coverArt, pointSize: artworkPointSize, isCircle: isCircle, fillsContainer: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.kmTileTitle)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(subtitle ?? " ")
                    .font(.kmTileSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
                    .opacity(subtitle == nil ? 0 : 1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Adaptive grid of tiles: ~160pt minimum on iPhone, ~190pt on iPad (2 columns portrait iPhone, 5 on iPad landscape).
struct AdaptiveAlbumGrid<Item: Identifiable, Content: View>: View {
    var items: [Item]
    var spacing: CGFloat = 16
    var content: (Item) -> Content

    @Environment(\.horizontalSizeClass) private var sizeClass

    init(items: [Item], spacing: CGFloat = 16, @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        let minimum: CGFloat = sizeClass == .regular ? 190 : 160
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: .top)], alignment: .leading, spacing: 20) {
            ForEach(items) { item in content(item) }
        }
        .padding(.horizontal, Theme.margin)
    }
}

/// "Recently Played ›" header + horizontally snapping shelf of tiles (150pt iPhone / 200pt iPad).
struct ShelfSection<Item: Identifiable, Content: View>: View {
    var title: String
    var items: [Item]
    var onHeaderTap: (() -> Void)?
    var content: (Item) -> Content

    @Environment(\.horizontalSizeClass) private var sizeClass

    init(title: String, items: [Item], onHeaderTap: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) {
        self.title = title
        self.items = items
        self.onHeaderTap = onHeaderTap
        self.content = content
    }

    var body: some View {
        let tileWidth: CGFloat = sizeClass == .regular ? 200 : 150
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, action: onHeaderTap)
                .padding(.horizontal, Theme.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        content(item).frame(width: tileWidth)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Theme.margin, for: .scrollContent)
        }
    }
}

/// 22pt bold title, with a chevron when tappable.
struct SectionHeader: View {
    var title: String
    var action: (() -> Void)?

    init(title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { label(showsChevron: true) }
                .buttonStyle(.plain)
        } else {
            label(showsChevron: false)
        }
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.kmSectionTitle).foregroundStyle(Theme.label)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isHeader)
    }
}
