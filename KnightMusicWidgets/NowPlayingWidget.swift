import SwiftUI
import WidgetKit
import AppIntents

struct NowPlayingTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NowPlayingTimelineProvider: TimelineProvider {
    typealias Entry = NowPlayingTimelineEntry

    func placeholder(in context: Context) -> NowPlayingTimelineEntry {
        NowPlayingTimelineEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                nowPlaying: WidgetNowPlaying(
                    title: "Song Title",
                    artist: "Artist Name",
                    album: "Album Name",
                    isPlaying: true,
                    duration: 210,
                    elapsed: 45
                )
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingTimelineEntry) -> Void) {
        let snapshot = WidgetSnapshot.read()
        completion(NowPlayingTimelineEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingTimelineEntry>) -> Void) {
        let snapshot = WidgetSnapshot.read()
        let entry = NowPlayingTimelineEntry(date: Date(), snapshot: snapshot)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Now Playing Widget Views

struct NowPlayingWidgetView: View {
    let entry: NowPlayingTimelineEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if let nowPlaying = entry.snapshot.nowPlaying {
                switch family {
                case .systemSmall:
                    NowPlayingSmallView(nowPlaying: nowPlaying)
                case .systemMedium:
                    NowPlayingMediumView(nowPlaying: nowPlaying)
                case .accessoryRectangular:
                    NowPlayingAccessoryRectangularView(nowPlaying: nowPlaying)
                default:
                    NowPlayingSmallView(nowPlaying: nowPlaying)
                }
            } else {
                NowPlayingEmptyView(family: family)
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground(hex: entry.snapshot.nowPlaying?.dominantColorHex)
        }
    }
}

// MARK: - System Small View

struct NowPlayingSmallView: View {
    let nowPlaying: WidgetNowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                ArtworkImage(filename: nowPlaying.artworkFilename)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1.5)

                Spacer()

                Button(intent: PlayPauseIntent()) {
                    Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(nowPlaying.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            if nowPlaying.duration > 0 {
                let start = nowPlaying.timestamp.addingTimeInterval(-nowPlaying.elapsed)
                let end = start.addingTimeInterval(max(nowPlaying.duration, 1))
                if nowPlaying.isPlaying {
                    ProgressView(timerInterval: start...end, countsDown: false)
                        .tint(.kmRed)
                } else {
                    ProgressView(value: min(nowPlaying.elapsed, nowPlaying.duration), total: max(nowPlaying.duration, 1))
                        .tint(.kmRed)
                }
            }
        }
    }
}

// MARK: - System Medium View

struct NowPlayingMediumView: View {
    let nowPlaying: WidgetNowPlaying

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(filename: nowPlaying.artworkFilename)
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 5, x: 0, y: 2.5)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(nowPlaying.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(nowPlaying.artist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)

                    if !nowPlaying.album.isEmpty {
                        Text(nowPlaying.album)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // Progress Bar with timer interval
                if nowPlaying.duration > 0 {
                    let start = nowPlaying.timestamp.addingTimeInterval(-nowPlaying.elapsed)
                    let end = start.addingTimeInterval(max(nowPlaying.duration, 1))
                    VStack(spacing: 2) {
                        if nowPlaying.isPlaying {
                            ProgressView(timerInterval: start...end, countsDown: false)
                                .tint(.kmRed)
                        } else {
                            ProgressView(value: min(nowPlaying.elapsed, nowPlaying.duration), total: max(nowPlaying.duration, 1))
                                .tint(.kmRed)
                        }

                        HStack {
                            if nowPlaying.isPlaying {
                                Text(timerInterval: start...end, pauseTime: nil, countsDown: false)
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.55))
                            } else {
                                Text(formatDuration(nowPlaying.elapsed))
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Text(formatDuration(nowPlaying.duration))
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }

                // Interactive control buttons
                HStack(spacing: 26) {
                    Button(intent: PreviousTrackIntent()) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)

                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.kmRed)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Accessory Rectangular View (Lock Screen)

struct NowPlayingAccessoryRectangularView: View {
    let nowPlaying: WidgetNowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: nowPlaying.isPlaying ? "speaker.wave.2.fill" : "music.note")
                    .font(.system(size: 10))
                Text(nowPlaying.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }

            Text(nowPlaying.artist)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if nowPlaying.duration > 0 {
                let start = nowPlaying.timestamp.addingTimeInterval(-nowPlaying.elapsed)
                let end = start.addingTimeInterval(max(nowPlaying.duration, 1))
                if nowPlaying.isPlaying {
                    ProgressView(timerInterval: start...end, countsDown: false)
                } else {
                    ProgressView(value: min(nowPlaying.elapsed, nowPlaying.duration), total: max(nowPlaying.duration, 1))
                }
            }
        }
    }
}

// MARK: - Empty State View

struct NowPlayingEmptyView: View {
    let family: WidgetFamily

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 2) {
                Label("Knight Music", systemImage: "music.note")
                    .font(.system(size: 12, weight: .bold))
                Text("Nothing playing")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: family == .systemSmall ? 26 : 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))

                Text("Nothing playing")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)

                Text("Tap to open")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Widget Declaration

struct NowPlayingWidget: Widget {
    static let kind = "com.knightabdo.knightmusic.widgets.nowplaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NowPlayingTimelineProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("See and control what's playing in Knight Music.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
