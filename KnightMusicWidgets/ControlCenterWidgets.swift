import WidgetKit
import SwiftUI
import AppIntents

struct PlayPauseControlWidget: ControlWidget {
    static let kind = "com.knightabdo.knightmusic.widgets.control.playpause"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: PlayPauseIntent()) {
                Label("Play/Pause", systemImage: "playpause.fill")
            }
        }
        .displayName("Play/Pause")
        .description("Play or pause music in Knight Music.")
    }
}

struct ShuffleLibraryControlWidget: ControlWidget {
    static let kind = "com.knightabdo.knightmusic.widgets.control.shuffle"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ShuffleLibraryIntent()) {
                Label("Shuffle Library", systemImage: "shuffle")
            }
        }
        .displayName("Shuffle Library")
        .description("Shuffles your entire music library in Knight Music.")
    }
}
