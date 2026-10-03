import SwiftUI

struct RootView: View {
    @State private var ui = UIState()
    @State private var nav = TabNavigationModel()
    @State private var hasAppliedDebugRouting = false
    @Namespace private var playerZoomNamespace

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
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

        ZStack(alignment: .top) {
            if shouldShowLogin {
                LoginView()
            } else {
                MainTabsView(playerZoomNamespace: playerZoomNamespace)
            }

            if let toast = ui.toast {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(toast)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 12)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .fullScreenCover(isPresented: $ui.isPlayerPresented) {
            FullPlayerView()
                .navigationTransition(.zoom(sourceID: "nowPlayingArtwork", in: playerZoomNamespace))
        }
        .tint(settings.accentColor)
        .animation(.smooth, value: ui.toast != nil)
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
