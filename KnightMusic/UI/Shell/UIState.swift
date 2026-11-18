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
    var toastID = UUID()
    var toastActionTitle: String?
    var toastAction: (@MainActor () -> Void)?
    /// Messages waiting behind the one on screen; shown in order instead of replacing it.
    private var queuedToasts: [QueuedToast] = []
    private struct QueuedToast {
        var message: String
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
    }
    /// How long the toast on screen stays: action toasts need time to be read and tapped, and a backlog moves faster.
    var toastDuration: Double {
        if toastAction != nil { return 8 }
        return queuedToasts.isEmpty ? 3 : 2
    }
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
    var recognitionTrack: RecognizedTrack?
    var recognitionAction: RecognizedSongAction?
    /// Present the next screen only after the recognition sheet has finished dismissing.
    enum RecognitionFollowUp {
        case player
        case playlist(Song)
        case importSong(Song)
    }
    var recognitionFollowUp: RecognitionFollowUp?
    var recognitionFollowUpAccountId: UUID?

    func startRecognition() {
        recognitionTrack = nil
        recognitionAction = nil
        recognitionFollowUp = nil
        recognitionFollowUpAccountId = nil
        recognitionShouldStart = true
        isRecognitionPresented = true
    }

    func openRecognition(_ track: RecognizedTrack, action: RecognizedSongAction? = nil) {
        recognitionTrack = track
        recognitionAction = action
        recognitionFollowUp = nil
        recognitionFollowUpAccountId = nil
        recognitionShouldStart = false
        isRecognitionPresented = true
    }

    func open(_ route: Route) { pendingRoute = route }

    func showToast(_ message: String) {
        showToast(message, actionTitle: nil, action: nil)
    }

    func showToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {
        let item = QueuedToast(message: message, actionTitle: actionTitle, action: action)
        guard toast != nil else {
            present(item)
            return
        }
        // Same plain message again: keep the one on screen and restart its timer.
        if toast == message, action == nil, toastAction == nil {
            toastID = UUID()
            return
        }
        if let last = queuedToasts.last, last.message == message, action == nil, last.action == nil { return }
        queuedToasts.append(item)
        // Never let a long backlog pile up: drop the oldest plain messages first.
        while queuedToasts.count > 6, let drop = queuedToasts.firstIndex(where: { $0.action == nil }) {
            queuedToasts.remove(at: drop)
        }
    }

    func dismissToast() {
        if queuedToasts.isEmpty {
            toast = nil
            toastActionTitle = nil
            toastAction = nil
        } else {
            present(queuedToasts.removeFirst())
        }
    }

    private func present(_ item: QueuedToast) {
        toastActionTitle = item.actionTitle
        toastAction = item.action
        toastID = UUID()
        toast = item.message
    }

    func askKnight(_ prompt: String) {
        knightDraft = prompt
        selectedTab = .knight
    }
}

