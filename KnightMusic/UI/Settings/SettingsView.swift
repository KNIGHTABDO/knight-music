import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings

    @State private var serverInfo = ServerInfoFetcher.shared
    @State private var showingLogoutConfirmation = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var statusText: String {
        if app.addressResolver.isResolving {
            return "Checking…"
        }
        if app.isOffline || !app.serverReachable {
            return "Offline"
        }
        return "Online"
    }

    private var statusColor: Color {
        if app.addressResolver.isResolving {
            return Theme.secondaryLabel
        }
        if app.isOffline || !app.serverReachable {
            return .red
        }
        return .green
    }

    private var serverFooterText: String {
        let type = serverInfo.pingResult?.type ?? "navidrome"
        if let version = serverInfo.pingResult?.serverVersion {
            return "\(type) \(version)"
        } else if let apiVersion = serverInfo.pingResult?.version {
            return "\(type) (API \(apiVersion))"
        }
        return type
    }

    var body: some View {
        @Bindable var settings = settings

        List {
            // 1. Account card
            Section {
                NavigationLink(destination: ServersView()) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 60, height: 60)
                            Image(systemName: "person.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Color.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.activeAccount?.name ?? "Knight Music")
                                .font(.title3)
                                .bold()
                                .foregroundStyle(Theme.label)
                            Text("Manage servers, addresses, sync…")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // 2. Status row
            Section {
                NavigationLink(destination: ServerStatusView()) {
                    HStack {
                        Text("Status")
                            .font(.kmRowTitle)
                            .foregroundStyle(Theme.label)
                        Spacer()
                        Text(statusText)
                            .font(.kmRowTitle)
                            .foregroundStyle(statusColor)
                    }
                }
            } footer: {
                Text(serverFooterText)
            }

            // 3. Offline Mode
            Section {
                HStack {
                    Text("Offline Mode")
                        .font(.kmRowTitle)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Menu {
                        Button {
                            settings.offlineMode = .automatic
                        } label: {
                            HStack {
                                Text("Automatic")
                                if settings.offlineMode == .automatic {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Button {
                            settings.offlineMode = .manual
                        } label: {
                            HStack {
                                Text("Manual")
                                if settings.offlineMode == .manual {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(settings.offlineMode == .automatic ? "Automatic" : "Manual")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }

                if settings.offlineMode == .manual {
                    Toggle("Enabled", isOn: $settings.manualOfflineEnabled)
                        .tint(Theme.accent)
                }
            } footer: {
                Text("When set to Automatic, Knight Music will automatically switch to offline mode when no connection to your server is available. In Manual mode, you control offline behavior.")
            }

            // 4. Sub-settings navigation
            Section {
                NavigationLink("Playback", destination: PlaybackSettingsView())
                NavigationLink("Storage", destination: StorageView())
                NavigationLink("Customize", destination: CustomizeView())
            }

            // 5. Log Out row
            Section {
                Button(role: .destructive) {
                    showingLogoutConfirmation = true
                } label: {
                    Text("Log Out")
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 6. App Version & Diagnostics
            Section {
                NavigationLink(destination: AboutView()) {
                    HStack {
                        Text("App Version")
                            .foregroundStyle(Theme.label)
                        Spacer()
                        Text("\(appVersion) (\(appBuild))")
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }

                NavigationLink("Diagnostics", destination: DiagnosticsView())
            }

            // 7. GitHub link row
            Section {
                Link(destination: URL(string: "https://github.com/KNIGHTABDO/knight-music")!) {
                    HStack {
                        Text("GitHub")
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Settings")
        .task {
            await serverInfo.fetchIfNeeded(app: app)
        }
        .refreshable {
            await serverInfo.fetchIfNeeded(app: app)
        }
        .confirmationDialog(
            "Log Out",
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                app.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to log out? Cached and downloaded songs for this server will be deleted.")
        }
    }
}
