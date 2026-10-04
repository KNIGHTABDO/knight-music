import SwiftUI

/// Settings for configuring the Hermes AI server connection.
struct HermesSettingsView: View {
    @Environment(HermesService.self) private var hermes
    @Environment(\.dismiss) private var dismiss

    @State private var serverURLString: String = ""
    @State private var apiKeyString: String = ""
    @State private var isTesting = false
    @State private var testOutcome: TestOutcome?

    private enum TestOutcome {
        case success(version: String)
        case failure(message: String)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server URL")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                    TextField("https://...", text: $serverURLString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                    SecureField("Bearer token", text: $apiKeyString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Button("Reset to Default URL") {
                    serverURLString = HermesSettings.defaultBaseURL
                    saveSettings()
                }
                .foregroundStyle(Theme.accent)
            } header: {
                Text("Connection")
            } footer: {
                Text("For security, Hermes agent should run on your private Tailscale network. Your API key is stored securely in the device Keychain.")
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("Test Connection")
                            .foregroundStyle(isTesting ? Theme.secondaryLabel : Theme.accent)
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isTesting)

                if let outcome = testOutcome {
                    switch outcome {
                    case .success(let version):
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text("Connected · hermes-agent \(version)")
                                .font(.subheadline)
                                .foregroundStyle(Color.green)
                        }
                    case .failure(let message):
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.red)
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(Color.red)
                        }
                    }
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Knight AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    saveSettings()
                    dismiss()
                }
                .font(.headline)
            }
        }
        .onAppear {
            serverURLString = hermes.settings.baseURLString
            apiKeyString = hermes.settings.apiKey
        }
        .onChange(of: serverURLString) { _, _ in
            saveSettings()
        }
        .onChange(of: apiKeyString) { _, _ in
            saveSettings()
        }
    }

    private func saveSettings() {
        hermes.settings.baseURLString = serverURLString
        hermes.settings.apiKey = apiKeyString
    }

    private func testConnection() async {
        saveSettings()
        isTesting = true
        testOutcome = nil

        do {
            await hermes.client.update(baseURL: hermes.settings.baseURL, apiKey: hermes.settings.apiKey)
            let health = try await hermes.client.health()
            _ = try await hermes.client.checkAuth()
            let version = health.version ?? "0.21.3"

            testOutcome = .success(version: version)
        } catch {
            testOutcome = .failure(message: error.localizedDescription)
        }
        isTesting = false
    }
}
