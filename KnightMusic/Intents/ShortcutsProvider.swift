import AppIntents

public struct KnightMusicShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play album \(\.$album) on \(.applicationName)",
                "Play \(\.$album) in \(.applicationName)",
                "Play \(\.$album) on \(.applicationName)"
            ],
            shortTitle: "Play Album",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play artist \(\.$artist) on \(.applicationName)",
                "Play \(\.$artist) on \(.applicationName)",
                "Play \(\.$artist) in \(.applicationName)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "person.2.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play playlist \(\.$playlist) on \(.applicationName)",
                "Play \(\.$playlist) on \(.applicationName)",
                "Play \(\.$playlist) in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play song \(\.$song) on \(.applicationName)",
                "Play \(\.$song) on \(.applicationName)",
                "Play \(\.$song) in \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "Shuffle library on \(.applicationName)",
                "Shuffle my library in \(.applicationName)",
                "Shuffle \(.applicationName)"
            ],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayFavoritesIntent(),
            phrases: [
                "Play favorites on \(.applicationName)",
                "Play my favorites in \(.applicationName)",
                "Play favorite songs on \(.applicationName)"
            ],
            shortTitle: "Play Favorites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayDownloadsIntent(),
            phrases: [
                "Play downloads on \(.applicationName)",
                "Play downloaded songs in \(.applicationName)",
                "Play offline music on \(.applicationName)"
            ],
            shortTitle: "Play Downloads",
            systemImageName: "arrow.down.circle.fill"
        )
        AppShortcut(
            intent: ResumeIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue \(.applicationName)",
                "Play music on \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PauseIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Stop \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "Next song on \(.applicationName)",
                "Next track in \(.applicationName)",
                "Skip song on \(.applicationName)"
            ],
            shortTitle: "Next Song",
            systemImageName: "forward.fill"
        )
    }

    public static func updateParameters() {
        updateAppShortcutParameters()
    }
}
