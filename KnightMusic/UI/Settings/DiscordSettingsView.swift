import SwiftUI

struct DiscordSettingsView: View {
    @Environment(DiscordPresenceService.self) private var discord
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput: String = ""
    @State private var isTokenVisible: Bool = false
    @State private var isTesting: Bool = false
    @State private var showCopiedAlert: Bool = false

    private let consoleSnippet = "window.webpackChunkdiscord_app.push([[''],{},e=>{m=[];for(let c in e.c)m.push(e.c[c])}]),m.find(m=>m?.exports?.default?.getToken!==void 0).exports.default.getToken()"

    var body: some View {
        @Bindable var settings = discord.settings

        List {
            // Status & Master Toggle Section
            Section {
                Toggle("Enable Discord Presence", isOn: $settings.isEnabled)
                    .tint(Theme.accent)

                HStack {
                    Text("Gateway Status")
                        .font(.kmRowTitle)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    statusBadge
                }
            } header: {
                Text("Service")
            } footer: {
                Text("Streams what you are listening to in real-time to your Discord profile with zero delay.")
            }

            // Token Configuration Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Discord User Token")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                        Spacer()
                        Button {
                            isTokenVisible.toggle()
                        } label: {
                            Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        if isTokenVisible {
                            TextField("Paste Discord Token", text: $tokenInput)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else {
                            SecureField("Paste Discord Token", text: $tokenInput)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }

                        if !tokenInput.isEmpty {
                            Button {
                                tokenInput = ""
                                settings.token = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.secondaryLabel)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if UIPasteboard.general.hasStrings {
                        Button {
                            if let paste = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !paste.isEmpty {
                                tokenInput = paste
                                settings.token = paste
                                Haptics.impact(.light)
                            }
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 2)

                Button {
                    Task {
                        settings.token = tokenInput
                        settings.isEnabled = true
                        isTesting = true
                        await discord.testConnection()
                        isTesting = false
                    }
                } label: {
                    HStack {
                        Text("Test & Connect")
                            .foregroundStyle(isTesting ? Theme.secondaryLabel : Theme.accent)
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isTesting || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Account Credentials")
            } footer: {
                Text("Your token is saved exclusively to your device's encrypted Keychain and connects directly to Discord's official Gateway.")
            }

            // Display Preferences Section
            Section {
                Toggle("Show Album Artwork", isOn: $settings.showArtwork)
                    .tint(Theme.accent)

                Toggle("Clear Status on Pause", isOn: $settings.clearOnPause)
                    .tint(Theme.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Activity App Name")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                    TextField("Knight Music", text: $settings.activityName)
                        .autocorrectionDisabled()
                }
                .padding(.vertical, 2)
            } header: {
                Text("Display Options")
            } footer: {
                Text("When Clear Status on Pause is active, the listening activity disappears from your profile when music is stopped or paused, matching Spotify's behavior.")
            }

            // Guidance Section
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("How to Get Your Token", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.label)

                    Text("1. Log in to Discord in any browser on your computer or phone.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)

                    Text("2. Open Developer Tools (press F12 or Cmd+Option+I on Mac).")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)

                    Text("3. Switch to the Console tab, paste this command, and press Enter:")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)

                    HStack {
                        Text(consoleSnippet)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.label)
                            .lineLimit(2)
                            .padding(8)
                            .background(Theme.secondaryBackground)
                            .cornerRadius(6)

                        Button {
                            UIPasteboard.general.string = consoleSnippet
                            Haptics.impact(.medium)
                            showCopiedAlert = true
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(Theme.accent)
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("4. Copy the returned token (without quotes) and paste it into the field above.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Setup Guide")
            } footer: {
                Text("Never share your Discord token with anyone else.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground.ignoresSafeArea())
        .navigationTitle("Discord Presence")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tokenInput = settings.token
        }
        .onChange(of: tokenInput) { _, newValue in
            settings.token = newValue
        }
        .alert("Copied to Clipboard", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Console script copied to clipboard.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch discord.settings.state {
        case .connected(let username):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("Connected as @\(username)")
                    .font(.subheadline)
                    .foregroundStyle(Color.green)
            }
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
            }
        case .disconnected:
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text("Disconnected")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }
}
