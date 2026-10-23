import SwiftUI

extension FocusedValues {
    /// The focused window's UI state, so menu commands act on the window the user is in.
    @Entry var windowUIState: UIState?
}

/// Hardware-keyboard shortcuts (hold ⌘ on iPad to see them).
struct PlaybackCommands: Commands {
    let player: PlayerEngine
    @FocusedValue(\.windowUIState) private var ui

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") {
                player.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.currentSong == nil)

            Button("Next Song") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.currentSong == nil)

            Button("Previous Song") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.currentSong == nil)

            Divider()

            Button(player.currentSong?.starred == nil ? "Love" : "Unlove") {
                player.toggleStarCurrent()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(player.currentSong == nil)

            Button("Show Player") { ui?.isPlayerPresented = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(player.currentSong == nil || ui == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Search") {
                ui?.isPlayerPresented = false
                ui?.selectedTab = .search
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(ui == nil)
        }
    }
}
