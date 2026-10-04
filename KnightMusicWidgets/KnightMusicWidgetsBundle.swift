import SwiftUI
import WidgetKit

@main
struct KnightMusicWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentlyPlayedWidget()
        LockScreenWidget()
        PlayPauseControlWidget()
        ShuffleLibraryControlWidget()
    }
}
