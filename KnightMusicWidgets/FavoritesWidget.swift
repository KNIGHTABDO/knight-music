import AppIntents
import SwiftUI
import WidgetKit

struct FavoritesTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct FavoritesTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FavoritesTimelineEntry {
        FavoritesTimelineEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (FavoritesTimelineEntry) -> Void) {
        completion(FavoritesTimelineEntry(date: Date(), snapshot: WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FavoritesTimelineEntry>) -> Void) {
        let entry = FavoritesTimelineEntry(date: Date(), snapshot: WidgetSnapshot.read())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - View

struct FavoritesWidgetView: View {
    let entry: FavoritesTimelineEntry
    @Environment(\.widgetFamily) var family

    private var songs: [WidgetSong] { entry.snapshot.favorites }

    var body: some View {
        Group {
            if songs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.kmRed)
                    Text("No Favorites Yet")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Tap the heart on a song to add it here")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch family {
                case .systemSmall:
                    FavoritesSmallView(songs: songs, count: entry.snapshot.favoriteCount)
                case .systemLarge:
                    FavoritesGridView(songs: Array(songs.prefix(8)), count: entry.snapshot.favoriteCount)
                default:
                    FavoritesGridView(songs: Array(songs.prefix(4)), count: entry.snapshot.favoriteCount)
                }
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground(hex: nil)
        }
        .widgetURL(URL(string: "knightmusic://favorites"))
    }
}

// MARK: - Small

struct FavoritesSmallView: View {
    let songs: [WidgetSong]
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                ArtworkImage(filename: songs.first?.artworkFilename)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1.5)

                Spacer()

                FavoritesShuffleButton(compact: true)
            }

            Spacer(minLength: 0)

            Label("Favorites", systemImage: "heart.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .labelStyle(FavoritesHeartLabelStyle())

            Text(count == 1 ? "1 song" : "\(count) songs")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

// MARK: - Medium / Large

struct FavoritesGridView: View {
    let songs: [WidgetSong]
    let count: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Favorites", systemImage: "heart.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .labelStyle(FavoritesHeartLabelStyle())
                Spacer()
                FavoritesShuffleButton(compact: false)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(songs) { song in
                    Button(intent: PlayFavoriteSongIntent(songId: song.id)) {
                        FavoriteSongTile(song: song)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct FavoriteSongTile: View {
    let song: WidgetSong

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkImage(filename: song.artworkFilename)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1.5)

            Text(song.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let artist = song.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }
}

struct FavoritesShuffleButton: View {
    let compact: Bool

    var body: some View {
        Button(intent: PlayFavoritesIntent()) {
            if compact {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.kmRed)
                    .clipShape(Circle())
            } else {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.kmRed)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle Favorites")
    }
}

private struct FavoritesHeartLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(Color.kmRed)
            configuration.title
        }
    }
}

// MARK: - Widget Declaration

struct FavoritesWidget: Widget {
    static let kind = "com.knightabdo.knightmusic.widgets.favorites"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FavoritesTimelineProvider()) { entry in
            FavoritesWidgetView(entry: entry)
        }
        .configurationDisplayName("Favorites")
        .description("Play or shuffle your favorite songs right from the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
