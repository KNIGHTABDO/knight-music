import SwiftUI

struct RootView: View {
    @State private var ui = UIState()
    @State private var nav = TabNavigationModel()
    @State private var hasAppliedDebugRouting = false
    @Namespace private var playerZoomNamespace

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var shouldShowLogin: Bool {
        if app.debugScreen == "onboarding" {
            return true
        }
        if app.activeAccount == nil {
            switch app.session {
            case .loggedOut, .connecting, .failed:
                return true
            case .ready:
                return false
            }
        }
        return false
    }

    var body: some View {
        @Bindable var ui = ui

        Group {
            if shouldShowLogin {
                LoginView()
            } else {
                MainTabsView(playerZoomNamespace: playerZoomNamespace)
            }
        }
        .overlay(alignment: .top) {
            if !shouldShowLogin, updates.showsBanner, let release = updates.available {
                UpdateBanner(release: release)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: updates.showsBanner)
        .focusedSceneValue(\.windowUIState, ui)
        .modifier(SongInfoPresenter(insidePlayer: false))
        .modifier(ShellBannersPresenter(insidePlayer: false))
        .fullScreenCover(isPresented: $ui.isPlayerPresented) {
            FullPlayerView()
                .modifier(SongInfoPresenter(insidePlayer: true))
                .modifier(ShellBannersPresenter(insidePlayer: true))
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
                .navigationTransition(.zoom(sourceID: "nowPlayingArtwork", in: playerZoomNamespace))
        }
        .sheet(isPresented: $ui.isRecognitionPresented) {
            MusicRecognitionSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMusicRecognition)) { _ in
            ui.isRecognitionPresented = true
        }
        .tint(LookStore.shared.accent)
        .environment(ui)
        .environment(nav)
        .task(id: ui.toast) {
            guard ui.toast != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.smooth) {
                ui.toast = nil
            }
        }
        .onChange(of: library.lastError) { _, newError in
            if let newError {
                withAnimation(.smooth) {
                    ui.showToast(newError)
                }
                library.lastError = nil
            }
        }
        .libraryDeepLinks { route in ui.open(route) }
        .onChange(of: ui.pendingRoute) { _, route in
            guard let route else { return }
            ui.pendingRoute = nil
            if ui.isPlayerPresented {
                ui.isPlayerPresented = false
                Task {
                    // Let the zoom dismissal finish so the push animates on the visible stack.
                    try? await Task.sleep(for: .milliseconds(450))
                    nav.open(route, in: ui)
                }
            } else {
                nav.open(route, in: ui)
            }
        }
        .onChange(of: player.lastError) { _, newError in
            if let newError {
                withAnimation(.smooth) {
                    ui.showToast(newError)
                }
                player.clearError()
            }
        }
        .task {
            await applyDebugRoutingIfNeeded()
        }
        .modifier(LookEffects(ui: ui))
        .task(id: player.currentSong?.id) {
            // Extract the current and next palettes before the player opens, so its first frame
            // already has the right colours.
            let palette = player.currentSong == nil ? nil : await ArtworkPalette.palette(for: player.currentSong?.coverArt)
            guard !Task.isCancelled else { return }
            LookStore.shared.updateArtwork(palette)
            _ = await ArtworkPalette.palette(for: player.upcoming.first?.song.coverArt)
        }
        .onChange(of: app.debugScreen) { _, _ in
            Task { await applyDebugRoutingIfNeeded() }
        }
        .onChange(of: app.session) { _, _ in
            Task { await applyDebugRoutingIfNeeded() }
        }
    }

    private func applyDebugRoutingIfNeeded() async {
        guard !hasAppliedDebugRouting else { return }
        guard let screen = app.debugScreen else { return }
        if screen == "onboarding" {
            hasAppliedDebugRouting = true
            return
        }
        guard app.session == .ready else { return }
        await app.waitForSync()
        try? await Task.sleep(nanoseconds: 300_000_000)
        hasAppliedDebugRouting = true
        let isRegular = horizontalSizeClass == .regular
        await DebugLaunch.applyRouting(
            screen: screen,
            app: app,
            ui: ui,
            nav: nav,
            isRegular: isRegular
        )
    }
}
