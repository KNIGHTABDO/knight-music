import SwiftUI

struct ServerStatusView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library

    @State private var serverInfo = ServerInfoFetcher.shared
    @State private var scanStatus: ScanStatus?
    @State private var extensions: [OpenSubsonicExtension] = []
    @State private var isLoading = false
    @State private var isScanning = false
    @State private var showingFullScanConfirmation = false
    @State private var errorMessage: String?

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

    var body: some View {
        List {
            Section("Server Status") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }

                HStack {
                    Text("Type")
                    Spacer()
                    Text(serverInfo.pingResult?.type?.capitalized ?? "Navidrome")
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Version")
                    Spacer()
                    Text(serverInfo.pingResult?.serverVersion ?? (serverInfo.pingResult?.version != nil ? "Subsonic \(serverInfo.pingResult!.version!)" : "—"))
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }

            Section("Server Scan Status") {
                HStack {
                    Text("Remote Folder Count")
                    Spacer()
                    Text(scanStatus?.folderCount.map(String.init) ?? "—")
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Remote Song Count")
                    Spacer()
                    Text(scanStatus?.count.map(String.init) ?? "—")
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Last Scan")
                    Spacer()
                    Text(formatLastScan(scanStatus?.lastScan))
                        .foregroundStyle(Theme.secondaryLabel)
                }

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(scanStatus?.count != nil ? "Scanning… \(scanStatus!.count!)" : "Scanning…")
                            .foregroundStyle(Theme.accent)
                    }
                } else {
                    Button {
                        Task { await triggerScan(full: false) }
                    } label: {
                        Text("Force Quick Scan")
                            .foregroundStyle(Theme.accent)
                    }

                    Button {
                        showingFullScanConfirmation = true
                    } label: {
                        Text("Full Scan")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            Section("Extensions") {
                if extensions.isEmpty && isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if extensions.isEmpty {
                    Text("No extensions reported")
                        .foregroundStyle(Theme.secondaryLabel)
                } else {
                    ForEach(extensions, id: \.name) { ext in
                        HStack {
                            Text(ext.name)
                                .font(.kmRowTitle)
                            Spacer()
                            Text(ext.versions?.description ?? "—")
                                .font(.kmRowSubtitle)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Server Status")
        .refreshable {
            await reloadAll()
        }
        .task {
            await reloadAll()
        }
        .confirmationDialog(
            "Full Scan",
            isPresented: $showingFullScanConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Full Scan", role: .destructive) {
                Task { await triggerScan(full: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A full scan scans all media files and may take several minutes on large libraries.")
        }
    }

    private func formatLastScan(_ date: Date?) -> String {
        guard let date else { return "—" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func reloadAll() async {
        isLoading = true
        errorMessage = nil
        await serverInfo.fetchIfNeeded(app: app)
        if let client = app.client {
            do {
                async let scan = client.getScanStatus()
                async let exts = client.getOpenSubsonicExtensions()
                let (s, e) = try await (scan, exts)
                self.scanStatus = s
                self.extensions = e
                self.isScanning = s.scanning
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func triggerScan(full: Bool) async {
        guard let client = app.client else { return }
        isScanning = true
        errorMessage = nil
        do {
            let started = try await client.startScan(fullScan: full)
            self.scanStatus = started
            while isScanning && !Task.isCancelled {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let current = try await client.getScanStatus()
                self.scanStatus = current
                if !current.scanning {
                    break
                }
            }
            await app.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        isScanning = false
    }
}
