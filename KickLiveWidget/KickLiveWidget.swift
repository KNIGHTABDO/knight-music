import SwiftUI
import WidgetKit

@main
struct KickLiveWidgetBundle: WidgetBundle {
    var body: some Widget {
        KickLiveWidget()
    }
}

struct KickLiveWidget: Widget {
    nonisolated static let kind = "KickLiveWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: KickLiveProvider()) { entry in
            KickLiveWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
        }
        .configurationDisplayName("Kick Live")
        .description("Which Kick streamers are live right now.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
