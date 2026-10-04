import MediaPlayer
import SwiftUI
import UIKit

/// Minimal system volume slider wrapping MPVolumeView to control hardware output level
/// without showing the system volume overlay HUD.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.tintColor = .white
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
        }
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if let slider = uiView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
        }
    }
}

/// Volume slider row with flanking speaker icons (used on iPhone portrait).
struct PlayerVolumeRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 16)

            SystemVolumeSlider()
                .frame(height: 32)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 16)
        }
        .padding(.horizontal, Theme.margin + 4)
    }
}
