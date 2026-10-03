import SwiftUI

/// First-launch connection screen for configuring the Navidrome server credentials and addresses.
struct LoginView: View {
    @Environment(AppModel.self) private var app

    @State private var serverName = "Navidrome"
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var additionalAddresses: [AdditionalAddressItem] = []
    @State private var isAdditionalExpanded = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    struct AdditionalAddressItem: Identifiable {
        let id = UUID()
        var address: String = ""
    }

    private var resolvedAddresses: [URL]? {
        guard let primary = AddressResolver.normalize(serverAddress) else { return nil }
        var list = [primary]
        for item in additionalAddresses {
            let trimmed = item.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let normalized = AddressResolver.normalize(trimmed) else { return nil }
                if !list.contains(normalized) {
                    list.append(normalized)
                }
            }
        }
        return list
    }

    private var isValid: Bool {
        guard resolvedAddresses != nil else { return false }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !password.isEmpty else { return false }
        return true
    }

    private var isBusy: Bool {
        isConnecting || app.session == .connecting
    }

    private var displayedError: String? {
        if let errorMessage { return errorMessage }
        if case .failed(let message) = app.session { return message }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.bottom, 4)

                    Text("Knight Music")
                        .font(.kmLargeTitle)
                        .foregroundStyle(Theme.label)

                    Text("Connect to your Navidrome server")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .padding(.top, 24)
                .padding(.bottom, 8)

                // Form Fields
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server name")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryLabel)
                        TextField("Navidrome", text: $serverName)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(uiColor: .systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(Theme.label)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server address")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryLabel)
                        TextField("https://music.example.com", text: $serverAddress)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(uiColor: .systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(Theme.label)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Username")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryLabel)
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(uiColor: .systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(Theme.label)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryLabel)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(uiColor: .systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(Theme.label)
                    }

                    // Additional Addresses Disclosure
                    DisclosureGroup("Additional addresses", isExpanded: $isAdditionalExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add alternative addresses (e.g. LAN IP, Tailscale). Knight Music checks all addresses and connects via the fastest reachable one.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryLabel)
                                .padding(.top, 4)

                            ForEach($additionalAddresses) { $item in
                                HStack(spacing: 8) {
                                    TextField("https://192.168.1.10:4533", text: $item.address)
                                        .keyboardType(.URL)
                                        .textContentType(.URL)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(Color(uiColor: .systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .foregroundStyle(Theme.label)

                                    Button {
                                        additionalAddresses.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(Color.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Button {
                                additionalAddresses.append(AdditionalAddressItem())
                            } label: {
                                Label("Add Address", systemImage: "plus.circle.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                        .padding(.top, 6)
                    }
                    .foregroundStyle(Theme.label)
                    .tint(Theme.accent)
                    .padding(14)
                    .background(Color(uiColor: .systemGray6).opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // Connect Action + Error
                VStack(spacing: 8) {
                    Button(action: connect) {
                        HStack(spacing: 8) {
                            if isBusy {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isBusy ? "Connecting…" : "Connect")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!isValid || isBusy)

                    if let displayedError {
                        Text(displayedError)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
    }

    private func connect() {
        guard let addresses = resolvedAddresses else { return }
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                let name = serverName.trimmingCharacters(in: .whitespaces)
                try await app.login(
                    name: name.isEmpty ? "Navidrome" : name,
                    addresses: addresses,
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
