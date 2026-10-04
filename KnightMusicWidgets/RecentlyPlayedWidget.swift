import SwiftUI
import WidgetKit

struct RecentlyPlayedTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct RecentlyPlayedTimelineProvider: TimelineProvider {
    typealias Entry = RecentlyPlayedTimelineEntry

    func placeholder(in context: Context) -> RecentlyPlayedTimelineEntry {
        RecentlyPlayedTimelineEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                recentAlbums: [
                    WidgetAlbum(id: "1", name: "Album One", artist: "Artist One"),
                    WidgetAlbum(id: "2", name: "Album Two", artist: "Artist Two"),
                    WidgetAlbum(id: "3", name: "Album Three", artist: "Artist Three"),
                    WidgetAlbum(id: "4", name: "Album Four", artist: "Artist Four")
                ]
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedTimelineEntry) -> Void) {
        let snapshot = WidgetSnapshot.read()
        completion(RecentlyPlayedTimelineEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedTimelineEntry>) -> Void) {
        let snapshot = WidgetSnapshot.read()
        let entry = RecentlyPlayedTimelineEntry(date: Date(), snapshot: snapshot)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Recently Played View

struct RecentlyPlayedWidgetView: View {
    let entry: RecentlyPlayedTimelineEntry
    @Environment(\.widgetFamily) var family

    private var albums: [WidgetAlbum] {
        entry.snapshot.recentAlbums.isEmpty ? entry.snapshot.newestAlbums : entry.snapshot.recentAlbums
    }

    var body: some View {
        Group {
            if albums.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No recent albums")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Play music to see albums here")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch family {
                case .systemMedium:
                    RecentlyPlayedMediumView(albums: Array(albums.prefix(4)))
                case .systemLarge:
                    RecentlyPlayedLargeView(albums: Array(albums.prefix(8)))
                default:
                    RecentlyPlayedMediumView(albums: Array(albums.prefix(4)))
                }
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground(hex: nil)
        }
    }
}

// MARK: - Medium (4 albums)

struct RecentlyPlayedMediumView: View {
    let albums: [WidgetAlbum]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently Played")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))

            HStack(alignment: .top, spacing: 10) {
                ForEach(albums) { album in
                    if let url = URL(string: "knightmusic://album/\(album.id)") {
                        Link(destination: url) {
                            AlbumGridTile(album: album)
                        }
                    } else {
                        AlbumGridTile(album: album)
                    }
                }

                // Fill remaining slots if fewer than 4
                if albums.count < 4 {
                    ForEach(0..<(4 - albums.count), id: \.self) { _ in
                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - Large (8 albums)

struct RecentlyPlayedLargeView: View {
    let albums: [WidgetAlbum]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently Played")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(albums) { album in
                    if let url = URL(string: "knightmusic://album/\(album.id)") {
                        Link(destination: url) {
                            AlbumGridTile(album: album)
                        }
                    } else {
                        AlbumGridTile(album: album)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Album Grid Tile

struct AlbumGridTile: View {
    let album: WidgetAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkImage(filename: album.artworkFilename)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1.5)

            Text(album.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let artist = album.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Widget Declaration

struct RecentlyPlayedWidget: Widget {
    static let kind = "com.knightabdo.knightmusic.widgets.recentlyplayed"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: RecentlyPlayedTimelineProvider()) { entry in
            RecentlyPlayedWidgetView(entry: entry)
        }
        .configurationDisplayName("Recently Played")
        .description("Quickly open your recently played albums in Knight Music.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
