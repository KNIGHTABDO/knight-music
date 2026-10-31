import ReplayKit
import SwiftUI
import UserNotifications

/// Starts the ReplayKit extension that identifies audio from other apps on this device, including on headphones.
/// iOS only opens its broadcast dialog from a tap on its own picker, so a clear picker sits above the styled label.
struct DeviceAudioBroadcastButton: View {
    var body: some View {
        VStack(spacing: 6) {
            Label("Listen to This Device", systemImage: "iphone.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                .overlay { BroadcastPicker() }

            Text("For songs playing in other apps, even on headphones. Tap Start Broadcast, then go back to your app.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = Bundle.main.bundleIdentifier.map { $0 + ".broadcast" }
        picker.showsMicrophoneButton = false
        picker.alpha = 0.02
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        for case let button as UIButton in picker.subviews {
            button.frame = picker.bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }
}
