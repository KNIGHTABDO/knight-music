import SwiftUI

/// "Browse" on the empty Search screen: the library's most played genres as colour tiles.
struct GenreBrowseGrid: View {
    @Environment(LibraryRepository.self) private var library

    var body: some View {
        let genres = library.topGenres(limit: 16)
        Group {
            if !genres.value.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Browse", route: .genres)
                        .padding(.horizontal, Theme.margin)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(genres.value) { genre in
                            NavigationLink(value: Route.genre(genre.value)) {
                                GenreBrowseTile(genre: genre)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                }
            }
        }
        .observing(genres)
    }
}

private struct GenreBrowseTile: View {
    let genre: Genre

    @Environment(LibraryRepository.self) private var library

    var body: some View {
        let albums = library.genreShelf(genre.value)
        let color = Self.color(for: genre.value)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [color, color.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)

            if let cover = albums.value.first?.coverArt {
                ArtworkView(coverArt: cover, pointSize: 72, cornerRadius: 6)
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(22))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .offset(x: 18, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            Text(genre.value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(genre.value)
        .accessibilityAddTraits(.isButton)
        .observing(albums)
    }

    /// Stable hue per genre name so tiles keep their colour between launches.
    private static func color(for name: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.62, brightness: 0.72)
    }
}
