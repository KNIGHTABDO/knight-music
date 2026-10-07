import SwiftUI

/// Quick settings sheet presented from the player's bottom bar:
/// - AutoMix and gapless playback toggles
/// - ReplayGain mode picker (off / track / album)
/// - Streaming quality options for Wi-Fi and Cellular
/// - Stream cache limit picker
struct PlaybackSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var player

    private var gaplessBinding: Binding<Bool> {
        Binding(
            get: { settings.gaplessEnabled },
            set: {
                settings.gaplessEnabled = $0
                player.settingsDidChange()
            }
        )
    }

    private var autoMixBinding: Binding<Bool> {
        Binding(
            get: { settings.autoMixEnabled },
            set: { settings.autoMixEnabled = $0 }
        )
    }

    private var replayGainBinding: Binding<AppSettings.ReplayGainMode> {
        Binding(
            get: { settings.replayGainMode },
            set: {
                settings.replayGainMode = $0
                player.settingsDidChange()
            }
        )
    }

    private var wifiQualityBinding: Binding<Int> {
        Binding(
            get: { settings.wifiMaxBitRate },
            set: {
                settings.wifiMaxBitRate = $0
                player.settingsDidChange()
            }
        )
    }

    private var cellularQualityBinding: Binding<Int> {
        Binding(
            get: { settings.cellularMaxBitRate },
            set: {
                settings.cellularMaxBitRate = $0
                player.settingsDidChange()
            }
        )
    }

    private var cacheLimitBinding: Binding<Int> {
        Binding(
            get: { settings.streamCacheLimitMB },
            set: { settings.streamCacheLimitMB = $0 }
        )
    }

    private var saveAheadBinding: Binding<AppSettings.SaveAheadMode> {
        Binding(
            get: { settings.saveAheadMode },
            set: {
                settings.saveAheadMode = $0
                player.settingsDidChange()
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("AutoMix", isOn: autoMixBinding)
                } footer: {
                    Text("Beat-matched transitions between songs, like a DJ.")
                }

                Section {
                    Toggle("Gapless Playback", isOn: gaplessBinding)

                    Picker("ReplayGain Mode", selection: replayGainBinding) {
                        Text("Off").tag(AppSettings.ReplayGainMode.off)
                        Text("Track").tag(AppSettings.ReplayGainMode.track)
                        Text("Album").tag(AppSettings.ReplayGainMode.album)
                    }
                } header: {
                    Text("Audio Playback")
                } footer: {
                    Text("ReplayGain equalizes perceived loudness across different tracks or albums.")
                }

                Section("Streaming Quality") {
                    Picker("Wi-Fi Quality", selection: wifiQualityBinding) {
                        Text("Original (No Limit)").tag(0)
                        Text("320 kbps").tag(320)
                        Text("256 kbps").tag(256)
                        Text("192 kbps").tag(192)
                        Text("128 kbps").tag(128)
                    }

                    Picker("Cellular Quality", selection: cellularQualityBinding) {
                        Text("Original (No Limit)").tag(0)
                        Text("320 kbps").tag(320)
                        Text("256 kbps").tag(256)
                        Text("192 kbps").tag(192)
                        Text("128 kbps").tag(128)
                    }
                }

                Section {
                    Picker("Stream Cache", selection: cacheLimitBinding) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("4 GB").tag(4096)
                    }

                    Picker("Save Next Songs Ahead", selection: saveAheadBinding) {
                        Text("Off").tag(AppSettings.SaveAheadMode.off)
                        Text("On Wi-Fi").tag(AppSettings.SaveAheadMode.wifiOnly)
                        Text("Always").tag(AppSettings.SaveAheadMode.always)
                    }
                } header: {
                    Text("Cache Limit")
                } footer: {
                    Text("Downloads the next songs in the background so playback doesn't stall on a weak connection.")
                }
            }
            .navigationTitle("Playback Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
