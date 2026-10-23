import SwiftUI
import WidgetKit

@main
struct KnightMusicWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentlyPlayedWidget()
        FavoritesWidget()
        LockScreenWidget()
        PlayPauseControlWidget()
        ShuffleLibraryControlWidget()
    }
}
