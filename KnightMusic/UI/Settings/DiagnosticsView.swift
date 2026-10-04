import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app

    @State private var logLines: [String] = []
    @State private var copied = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var activeAddressString: String {
        app.addressResolver.currentAddress?.absoluteString
            ?? app.client?.baseURL.absoluteString
            ?? app.activeAccount?.addresses.first?.absoluteString
            ?? "None"
    }

    var body: some View {
        List {
            Section("Device & App Info") {
                HStack {
                    Text("App Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("iOS Version")
                    Spacer()
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Active Server")
                    Spacer()
                    Text(app.activeAccount?.name ?? "None")
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Active Address")
                    Spacer()
                    Text(activeAddressString)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text("Network")
                    Spacer()
                    Text(app.network.isConnected ? "Connected" : "Disconnected")
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Offline State")
                    Spacer()
                    Text(app.isOffline ? "Offline" : "Online")
                        .foregroundStyle(app.isOffline ? .red : .green)
                }
            }

            Section {
                HStack(spacing: 12) {
                    ShareLink(item: Log.exportText()) {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = Log.exportText()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy) { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied!" : "Copy Logs", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                }

                Button(role: .destructive) {
                    Log.clear()
                    logLines = Log.recentLines
                } label: {
                    Text("Clear Logs")
                        .foregroundStyle(Theme.accent)
                }
            }

            Section("Recent Logs (\(logLines.count))") {
                if logLines.isEmpty {
                    Text("No logs recorded yet.")
                        .foregroundStyle(Theme.secondaryLabel)
                        .font(.footnote)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(logColor(for: line))
                                        .id(index)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 250, maxHeight: 380)
                        .onAppear {
                            if !logLines.isEmpty {
                                proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                            }
                        }
                        .onChange(of: logLines.count) {
                            if !logLines.isEmpty {
                                proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .task {
            logLines = Log.recentLines
        }
        .refreshable {
            logLines = Log.recentLines
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("[ERROR]") {
            return .red
        }
        if line.contains("[WARNING]") {
            return .orange
        }
        return Theme.secondaryLabel
    }
}
