import SwiftUI

struct AddressesView: View {
    @Environment(AppModel.self) private var app

    @State private var showingAddAlert = false
    @State private var newAddressText = ""
    @State private var errorMessage: String?

    private var activeAccount: ServerAccount? {
        app.accounts.active ?? app.activeAccount
    }

    private var currentResolvedAddress: URL? {
        app.addressResolver.currentAddress ?? app.client?.baseURL
    }

    var body: some View {
        List {
            if let account = activeAccount {
                Section {
                    ForEach(account.addresses, id: \.self) { address in
                        HStack(spacing: 12) {
                            if address == currentResolvedAddress {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            } else {
                                Circle()
                                    .fill(Color.clear)
                                    .frame(width: 8, height: 8)
                            }

                            Text(address.absoluteString)
                                .font(.kmRowTitle)
                                .foregroundStyle(Theme.label)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        deleteAddresses(at: offsets)
                    }
                    .onMove { source, destination in
                        moveAddresses(from: source, to: destination)
                    }
                } footer: {
                    Text("Knight Music tries addresses in this order and uses the first reachable one (e.g. home LAN first, then Tailscale).")
                }
            } else {
                Section {
                    Text("No server selected")
                        .foregroundStyle(Theme.secondaryLabel)
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
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Manage Addresses")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button {
                    showingAddAlert = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .alert("Add Address", isPresented: $showingAddAlert) {
            TextField("https://music.example.com", text: $newAddressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                addAddress()
            }
            Button("Cancel", role: .cancel) {
                newAddressText = ""
            }
        } message: {
            Text("Enter the server URL or IP address (e.g. 192.168.1.5:4533 or https://music.example.com).")
        }
    }

    private func addAddress() {
        errorMessage = nil
        let trimmed = newAddressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let normalized = AddressResolver.normalize(trimmed) else {
            errorMessage = "Please enter a valid URL (e.g. 192.168.1.5:4533 or https://music.example.com)."
            newAddressText = ""
            return
        }

        guard var account = activeAccount else { return }
        if account.addresses.contains(normalized) {
            errorMessage = "This address is already in the list."
            newAddressText = ""
            return
        }

        account.addresses.append(normalized)
        app.accounts.update(account)
        newAddressText = ""
        Task {
            await app.reresolveAddress()
        }
    }

    private func deleteAddresses(at offsets: IndexSet) {
        errorMessage = nil
        guard var account = activeAccount else { return }
        account.addresses.remove(atOffsets: offsets)
        app.accounts.update(account)
        Task {
            await app.reresolveAddress()
        }
    }

    private func moveAddresses(from source: IndexSet, to destination: Int) {
        errorMessage = nil
        guard var account = activeAccount else { return }
        account.addresses.move(fromOffsets: source, toOffset: destination)
        app.accounts.update(account)
        Task {
            await app.reresolveAddress()
        }
    }
}
