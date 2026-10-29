import SwiftUI

/// A BitChord-style mood or genre card with a vivid left stripe and dark gradient body.
struct YTMoodGenreCard: View {
    let item: YTMoodGenreItem

    private var baseColor: Color {
        if let hex = item.stripeColor, hex != 0 {
            let a = Double((hex >> 24) & 0xFF) / 255.0
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b, opacity: a > 0 ? a : 1.0)
        }
        var hash: UInt32 = 2_166_136_261
        for byte in item.title.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.65, brightness: 0.75)
    }

    var body: some View {
        NavigationLink(value: item.target.destinationRoute(title: item.title)) {
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [baseColor.mix(with: .black, by: 0.25), baseColor.mix(with: .black, by: 0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Rectangle()
                    .fill(baseColor)
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)

                Text(item.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .padding(.vertical, 10)
            }
            .frame(height: 76)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
    }
}

/// The complete Moods & Genres browse screen with grouped categories.
struct YTMoodsAndGenresView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        YTLoader(id: "moods_and_genres", load: { try await YouTubeMusic.shared.moodsAndGenres() }) { sections in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: section.title)
                                .padding(.horizontal, Theme.margin)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 150, maximum: 260), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(section.items) { item in
                                    YTMoodGenreCard(item: item)
                                }
                            }
                            .padding(.horizontal, Theme.margin)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle("Moods & Genres")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Embedded into SearchView when source == .youTube and query is empty.
struct YouTubeSearchBrowseView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Hero Discover Jump Banner
            NavigationLink(value: Route.youTubeDiscover) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 48, height: 48)
                        Image(systemName: "globe")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Discover YouTube Music")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.label)
                        Text("Explore For You, New Releases, Charts & Moods")
                            .font(.kmRowSubtitle)
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryLabel)
                }
                .padding(14)
                .background(Color(uiColor: .systemGray6).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding(.horizontal, Theme.margin)
            }
            .buttonStyle(.plain)

            // Moods & Genres preview
            YTLoader(id: "search_moods_and_genres", load: { try await YouTubeMusic.shared.moodsAndGenres() }) { sections in
                if let first = sections.first {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Moods & Genres", route: .youTubeMoodsAndGenres)
                            .padding(.horizontal, Theme.margin)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 150, maximum: 260), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(Array(first.items.prefix(12))) { item in
                                YTMoodGenreCard(item: item)
                            }
                        }
                        .padding(.horizontal, Theme.margin)
                    }
                }
            }
        }
    }
}
