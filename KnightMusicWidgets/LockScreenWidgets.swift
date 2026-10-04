import SwiftUI
import WidgetKit

struct LockScreenTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct LockScreenTimelineProvider: TimelineProvider {
    typealias Entry = LockScreenTimelineEntry

    func placeholder(in context: Context) -> LockScreenTimelineEntry {
        LockScreenTimelineEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                nowPlaying: WidgetNowPlaying(
                    title: "Song Title",
                    artist: "Artist Name",
                    album: "Album Name",
                    isPlaying: true,
                    duration: 200,
                    elapsed: 60
                )
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenTimelineEntry) -> Void) {
        let snapshot = WidgetSnapshot.read()
        completion(LockScreenTimelineEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenTimelineEntry>) -> Void) {
        let snapshot = WidgetSnapshot.read()
        let entry = LockScreenTimelineEntry(date: Date(), snapshot: snapshot)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Lock Screen View

struct LockScreenWidgetView: View {
    let entry: LockScreenTimelineEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            if let np = entry.snapshot.nowPlaying {
                let progress = np.duration > 0 ? min(np.elapsed / np.duration, 1.0) : 0
                Gauge(value: progress) {
                    Image(systemName: "music.note")
                } currentValueLabel: {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                }
            }

        case .accessoryInline:
            if let np = entry.snapshot.nowPlaying {
                ViewThatFits {
                    Text("♪ \(np.title) — \(np.artist)")
                    Text("♪ \(np.title)")
                }
            } else {
                Text("♪ Knight Music")
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Widget Declaration

struct LockScreenWidget: Widget {
    static let kind = "com.knightabdo.knightmusic.widgets.lockscreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LockScreenTimelineProvider()) { entry in
            LockScreenWidgetView(entry: entry)
        }
        .configurationDisplayName("Knight Music Lock Screen")
        .description("Track playback on your lock screen.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}
