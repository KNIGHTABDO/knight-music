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

    func showToast(_ message: String) { toast = message }

    func askKnight(_ prompt: String) {
        knightDraft = prompt
        selectedTab = .knight
    }
}

