import SwiftUI

/// Ten-band equalizer with Apple-Music-style presets. Applied by the audio tap on local files.
struct EqualizerView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Equalizer", isOn: $settings.eqEnabled)
                    .tint(Theme.accent)
            } footer: {
                Text("Applies to downloaded songs and songs saved on this device. While it is on, upcoming songs are saved ahead so the equalizer can shape them too.")
            }

            Section("Preset") {
                Picker("Preset", selection: presetBinding) {
                    ForEach(Equalizer.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    if Equalizer.preset(id: settings.eqPreset) == nil {
                        Text("Custom").tag(settings.eqPreset)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                ForEach(Equalizer.frequencies.indices, id: \.self) { band in
                    bandRow(band)
                }
            } header: {
                Text("Bands")
            } footer: {
                Button("Reset to Flat") { choose(preset: "flat") }
                    .foregroundStyle(Theme.accent)
                    .disabled(settings.eqGains == Equalizer.flat)
            }
            .disabled(!settings.eqEnabled)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground.ignoresSafeArea())
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: settings.eqPreset)
    }

    private var presetBinding: Binding<String> {
        Binding(get: { settings.eqPreset }, set: { choose(preset: $0) })
    }

    private func choose(preset id: String) {
        guard let preset = Equalizer.preset(id: id) else { return }
        withAnimation(.smooth) {
            settings.eqPreset = preset.id
            settings.eqGains = preset.gains
        }
    }

    private func bandRow(_ band: Int) -> some View {
        let gain = band < settings.eqGains.count ? settings.eqGains[band] : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.frequencyTitle(Equalizer.frequencies[band]))
                Spacer()
                Text(Self.gainTitle(gain))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: gainBinding(band), in: Equalizer.range, step: 0.5)
                .tint(Theme.accent)
        }
        .accessibilityElement(children: .combine)
    }

    private func gainBinding(_ band: Int) -> Binding<Double> {
        Binding(
            get: { band < settings.eqGains.count ? settings.eqGains[band] : 0 },
            set: { value in
                var gains = settings.eqGains.count == Equalizer.frequencies.count ? settings.eqGains : Equalizer.flat
                gains[band] = value
                settings.eqGains = gains
                settings.eqPreset = Equalizer.presets.first { $0.gains == gains }?.id ?? "custom"
            }
        )
    }

    private static func frequencyTitle(_ hz: Float) -> String {
        hz >= 1_000 ? "\((hz / 1_000).formatted()) kHz" : "\(Int(hz)) Hz"
    }

    private static func gainTitle(_ db: Double) -> String {
        (db > 0 ? "+" : "") + db.formatted(.number.precision(.fractionLength(1))) + " dB"
    }
}
