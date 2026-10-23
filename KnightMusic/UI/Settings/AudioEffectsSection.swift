import SwiftUI

/// Crossfade, playback speed and the equalizer; shared by Settings → Playback and the player's quick settings.
struct AudioEffectsSection: View {
    @Environment(AppSettings.self) private var settings

    static let crossfadeOptions = [0, 2, 4, 6, 8, 10, 12]
    static let speedOptions: [Double] = [0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Crossfade", selection: $settings.crossfadeSeconds) {
                ForEach(Self.crossfadeOptions, id: \.self) { seconds in
                    Text(seconds == 0 ? "Off" : "\(seconds) s").tag(seconds)
                }
            }
            .disabled(settings.autoMixEnabled)

            Picker("Playback Speed", selection: $settings.playbackSpeed) {
                ForEach(Self.speedOptions, id: \.self) { speed in
                    Text(Self.speedTitle(speed)).tag(speed)
                }
            }

            NavigationLink {
                EqualizerView()
            } label: {
                LabeledContent("Equalizer", value: Self.equalizerSummary(settings))
            }
        } header: {
            Text("Transitions & Sound")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        if settings.autoMixEnabled {
            return "Crossfade is used when AutoMix is off. Transitions pause while the playback speed is changed."
        }
        return "Crossfade fades each song into the next. Transitions pause while the playback speed is changed."
    }

    static func speedTitle(_ speed: Double) -> String {
        speed == 1 ? "Normal" : speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    static func equalizerSummary(_ settings: AppSettings) -> String {
        guard settings.eqEnabled else { return "Off" }
        return Equalizer.preset(id: settings.eqPreset)?.name ?? "Custom"
    }
}
