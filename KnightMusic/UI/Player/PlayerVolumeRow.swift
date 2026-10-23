import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Reads the hardware output volume (KVO on AVAudioSession) and writes it through a hidden
/// MPVolumeView's slider, the only public way to set the system volume. Keeping that MPVolumeView
/// on screen also stops iOS from drawing its volume HUD over the player.
@MainActor @Observable
final class SystemVolumeController {
    private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored weak var slider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.volume = value }
        }
    }

    func set(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        slider?.setValue(clamped, animated: false)
        slider?.sendActions(for: .valueChanged)
    }

    /// One hardware button press is 1/16 of the range.
    func step(_ direction: Float) {
        set(volume + direction / 16)
    }
}

/// Invisible MPVolumeView that hands its slider to the controller.
private struct HiddenVolumeView: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        view.alpha = 0.011
        view.isUserInteractionEnabled = false
        controller.slider = view.subviews.compactMap { $0 as? UISlider }.first
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if controller.slider == nil {
            controller.slider = uiView.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}

/// Volume bar styled like the scrubber, with speaker buttons that step the volume.
struct PlayerVolumeRow: View {
    @State private var controller = SystemVolumeController()
    @State private var isDragging = false
    @State private var dragStartVolume: Float = 0

    var body: some View {
        HStack(spacing: 12) {
            stepButton(symbol: "speaker.fill", direction: -1, label: "Volume Down")

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let height: CGFloat = isDragging ? 10 : 6
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(Color.white.opacity(isDragging ? 1 : 0.85))
                        .frame(width: width * CGFloat(controller.volume))
                }
                .frame(height: height)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartVolume = controller.volume
                                Haptics.impact(.light)
                            }
                            controller.set(dragStartVolume + Float(value.translation.width / width))
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .frame(height: 32)
            .background(alignment: .center) { HiddenVolumeView(controller: controller).frame(width: 1, height: 1) }
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((controller.volume * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                controller.step(direction == .increment ? 1 : -1)
            }

            stepButton(symbol: "speaker.wave.3.fill", direction: 1, label: "Volume Up")
        }
        .padding(.horizontal, Theme.margin + 4)
    }

    private func stepButton(symbol: String, direction: Float, label: String) -> some View {
        Button {
            Haptics.selection()
            controller.step(direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 28, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
