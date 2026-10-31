import SwiftUI

/// App-wide UI state shared by the shell and screens (injected with `.environment(uiState)` by RootView).
@MainActor @Observable
final class UIState {
    enum Tab: Hashable {
        case home, search, settings, library, knight
        case section(Route)   // iPad sidebar library entries
    }

    enum PlayerPanel: Hashable { case artwork, lyrics, queue }

    var selectedTab: Tab = .home
    var isPlayerPresented = false
    var playerPanel: PlayerPanel = .artwork
    /// Transient message shown as a toast by the shell (errors, "Added to queue", …).
    var toast: String?
    /// Draft prompt to pre-fill when switching to Knight tab.
    var knightDraft: String?
    /// Knight conversation to open when switching to the Knight tab (e.g. a Navidrome import).
    var knightConversation: String?
    /// Set from anywhere (including the full player, which has no NavigationStack); the shell
    /// dismisses the player and pushes it onto the visible tab.
    var pendingRoute: Route?
    /// Song whose info sheet is showing (see `SongInfoPresenter`).
    var songInfo: Song?
    /// Songs being added to a playlist (see `SongInfoPresenter`).
    var playlistPicker: PlaylistPickerRequest?
    /// Whether the music recognition sheet is presented.
    var isRecognitionPresented = false

    /// Set when the sheet should begin a new recognition instead of showing the one in progress or just finished.
    var recognitionShouldStart = false
    /// iOS drops a cover requested while a sheet is still dismissing, so RootView presents it from onDismiss.
    var playerAfterRecognition = false

    func startRecognition() {
        recognitionShouldStart = true
        isRecognitionPresented = true
    }

    func open(_ route: Route) { pendingRoute = route }

    func showToast(_ message: String) { toast = message }

    func askKnight(_ prompt: String) {
        knightDraft = prompt
        selectedTab = .knight
    }
}

