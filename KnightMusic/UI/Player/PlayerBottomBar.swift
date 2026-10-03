import AVKit
import SwiftUI

/// Minimal wrapper around AVRoutePickerView for AirPlay output selection.
struct RoutePickerViewRepresentable: UIViewRepresentable {
    var tintColor: UIColor = .white
    var activeTintColor: UIColor = UIColor(Theme.accent)

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}

/// Floating glass bottom bar for FullPlayerView:
/// AirPlay · Playback settings · Dismiss · Lyrics · Queue · Sleep timer.
/// All controls are enclosed in a GlassEffectContainer with circular glass buttons.
struct PlayerBottomBar: View {
    @Environment(UIState.self) private var ui
    @Environment(PlayerEngine.self) private var player
    @Binding var isShowingSettings: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                // 1. AirPlay
                RoutePickerViewRepresentable()
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("AirPlay")

                // 2. Playback settings sheet
                Button {
                    Haptics.impact(.light)
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Playback Settings")

                // 3. Dismiss full player
                Button {
                    Haptics.impact(.light)
                    withAnimation(.smooth) {
                        ui.isPlayerPresented = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Dismiss Player")

                // 4. Lyrics toggle
                Button {
                    Haptics.impact(.light)
                    withAnimation(.smooth) {
                        ui.playerPanel = (ui.playerPanel == .lyrics) ? .artwork : .lyrics
                    }
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ui.playerPanel == .lyrics ? Theme.accent : Color.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Lyrics")

                // 5. Queue toggle
                Button {
                    Haptics.impact(.light)
                    withAnimation(.smooth) {
                        ui.playerPanel = (ui.playerPanel == .queue) ? .artwork : .queue
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ui.playerPanel == .queue ? Theme.accent : Color.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Queue")

                // 6. Sleep timer menu
                Menu {
                    if player.sleepTimer.isActive {
                        if let remaining = player.sleepTimer.remaining {
                            Text("Sleep timer: \(KMFormat.duration(remaining)) left")
                        }
                        Divider()
                    }

                    ForEach(SleepTimer.presetMinutes, id: \.self) { mins in
                        Button("\(mins) Minutes") {
                            Haptics.impact(.light)
                            player.sleepTimer.start(minutes: mins)
                        }
                    }

                    Button("End of Song") {
                        Haptics.impact(.light)
                        player.sleepTimer.startEndOfSong()
                    }

                    if player.sleepTimer.isActive {
                        Divider()
                        Button("Turn Off", role: .destructive) {
                            Haptics.impact(.light)
                            player.sleepTimer.cancel()
                        }
                    }
                } label: {
                    ZStack {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(player.sleepTimer.isActive ? Theme.accent : Color.white)

                        if player.sleepTimer.isActive {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 6, height: 6)
                                .offset(x: 10, y: -10)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Sleep Timer")
            }
        }
    }
}
