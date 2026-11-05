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
            intent: ResumeIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue \(.applicationName)",
                "Play music on \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(intent: LoveCurrentSongIntent(),
                    phrases: ["Love current song in \(.applicationName)", "Love this song on \(.applicationName)"],
                    shortTitle: "Love Current Song", systemImageName: "heart.fill")
        AppShortcut(intent: RecognizeSongIntent(),
                    phrases: ["Recognize song with \(.applicationName)", "Identify this song with \(.applicationName)"],
                    shortTitle: "Recognize Song", systemImageName: "waveform")
        AppShortcut(intent: AddCurrentSongToNavidromeIntent(),
                    phrases: ["Add current song to Navidrome with \(.applicationName)", "Save this YouTube song with \(.applicationName)"],
                    shortTitle: "Add to Navidrome", systemImageName: "plus.circle")
    }

    public static func updateParameters() {
        updateAppShortcutParameters()
    }
}
