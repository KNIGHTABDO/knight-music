import SwiftUI

struct ArtworkLoveGesture: ViewModifier {
    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui
    @State private var burst = false
    @State private var burstID = 0

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2, perform: love)
            .overlay {
                if burst {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 90, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .shadow(color: .black.opacity(0.3), radius: 12)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .help("Double-tap to toggle love")
            .accessibilityAction(named: "Toggle Love", love)
            .task(id: burstID) {
                guard burst else { return }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                withAnimation(.spring(response: 0.3)) { burst = false }
            }
    }

    private func love() {
        guard let song = player.currentSong, player.currentRadio == nil else { return }
        // YouTube streams have no server star endpoint; the menu offers importing them first.
        guard !song.isYouTube else {
            ui.showToast("Add to Navidrome to love this song")
            return
        }
        Haptics.impact(.medium)
        player.toggleStarCurrent()
        burstID += 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { burst = true }
    }
}
