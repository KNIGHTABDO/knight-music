import SwiftUI

struct PlaybackSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var player

    private let bitrateOptions = [0, 320, 256, 192, 128]
    private let formatOptions = ["raw", "mp3", "opus", "aac"]

    var body: some View {
        @Bindable var settings = settings

        List {
            Section("Streaming Quality") {
                Picker("Wi-Fi Quality", selection: $settings.wifiMaxBitRate) {
                    ForEach(bitrateOptions, id: \.self) { rate in
                        Text(bitrateTitle(rate)).tag(rate)
                    }
                }

                Picker("Wi-Fi Format", selection: $settings.wifiFormat) {
                    ForEach(formatOptions, id: \.self) { format in
                        Text(formatTitle(format)).tag(format)
                    }
                }

                Picker("Cellular Quality", selection: $settings.cellularMaxBitRate) {
                    ForEach(bitrateOptions, id: \.self) { rate in
                        Text(bitrateTitle(rate)).tag(rate)
                    }
                }

                Picker("Cellular Format", selection: $settings.cellularFormat) {
                    ForEach(formatOptions, id: \.self) { format in
                        Text(formatTitle(format)).tag(format)
                    }
                }
            }

            Section("Downloads") {
                Picker("Quality", selection: $settings.downloadMaxBitRate) {
                    ForEach(bitrateOptions, id: \.self) { rate in
                        Text(bitrateTitle(rate)).tag(rate)
                    }
                }

                Picker("Format", selection: $settings.downloadFormat) {
                    ForEach(formatOptions, id: \.self) { format in
                        Text(formatTitle(format)).tag(format)
                    }
                }
            }

            Section("Playback Options") {
                Toggle("Gapless Playback", isOn: $settings.gaplessEnabled)
                    .tint(Theme.accent)

                Toggle("Scrobble to Server", isOn: $settings.scrobblingEnabled)
                    .tint(Theme.accent)

                Toggle("Sync Play Queue with Server", isOn: $settings.syncPlayQueueWithServer)
                    .tint(Theme.accent)

                Toggle("Show Ratings", isOn: $settings.showRatings)
                    .tint(Theme.accent)

                Picker("ReplayGain", selection: $settings.replayGainMode) {
                    Text("Off").tag(AppSettings.ReplayGainMode.off)
                    Text("Track").tag(AppSettings.ReplayGainMode.track)
                    Text("Album").tag(AppSettings.ReplayGainMode.album)
                }
            }

            Section {
                Toggle("Animated Artwork", isOn: $settings.animatedArtworkEnabled)
                    .tint(Theme.accent)

                Toggle("Lock Screen Animated Artwork", isOn: $settings.lockScreenAnimatedArtworkEnabled)
                    .tint(Theme.accent)
            } header: {
                Text("Artwork")
            } footer: {
                Text("Animated artwork plays automatically on supported albums when available. Lock screen animated artwork requires Now Playing background support.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Playback")
        .onChange(of: settings.replayGainMode) {
            player.settingsDidChange()
        }
    }

    private func bitrateTitle(_ rate: Int) -> String {
        rate == 0 ? "Original" : "\(rate) kbps"
    }

    private func formatTitle(_ format: String) -> String {
        switch format.lowercased() {
        case "raw": return "Original"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "aac": return "AAC"
        default: return format.uppercased()
        }
    }
}
