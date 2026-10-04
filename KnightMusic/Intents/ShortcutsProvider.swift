import AppIntents

public struct KnightMusicShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play \(\.$album) in \(.applicationName)"
            ],
            shortTitle: "Play Album",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) on \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "Shuffle my library in \(.applicationName)"
            ],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayFavoritesIntent(),
            phrases: [
                "Play my favorites in \(.applicationName)"
            ],
            shortTitle: "Play Favorites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Pause \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "Next song in \(.applicationName)"
            ],
            shortTitle: "Next Song",
            systemImageName: "forward.fill"
        )
    }
}
