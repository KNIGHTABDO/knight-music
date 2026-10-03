import SwiftUI

struct ServersView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library

    @State private var showingAddServerSheet = false
    @State private var isRefreshing = false

    private var activeAccount: ServerAccount? {
        app.accounts.active ?? app.activeAccount
    }

    private var resolvedAddressString: String {
        app.addressResolver.currentAddress?.absoluteString
            ?? app.client?.baseURL.absoluteString
            ?? activeAccount?.addresses.first?.absoluteString
            ?? "—"
    }

    var body: some View {
        let counts = library.counts()

        List {
            Section("Servers") {
                ForEach(app.accounts.accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.name)
                                .font(.kmRowTitle)
                                .foregroundStyle(Theme.label)
                            Text(account.createdAt.formatted(date: .numeric, time: .shortened))
                                .font(.kmRowSubtitle)
                                .foregroundStyle(Theme.secondaryLabel)
                        }

                        Spacer()

                        if account.id == activeAccount?.id {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if account.id != activeAccount?.id {
                            app.switchAccount(id: account.id)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let account = app.accounts.accounts[index]
                        app.removeAccount(id: account.id)
                    }
                }
            }

            if let account = activeAccount {
                Section("Current Server") {
                    HStack {
                        Text("Display Name")
                        Spacer()
                        Text(account.name)
                            .foregroundStyle(Theme.secondaryLabel)
                    }

                    HStack {
                        Text("Username")
                        Spacer()
                        Text(account.username)
                            .foregroundStyle(Theme.secondaryLabel)
                    }

                    NavigationLink(destination: AddressesView()) {
                        HStack {
                            Text("Manage Addresses")
                            Spacer()
                            Text("\(account.addresses.count)")
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }

                    HStack {
                        Text("Resolved Address")
                        Spacer()
                        Text(resolvedAddressString)
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        if app.syncStatus.isSyncing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(app.syncStatus.phase.isEmpty ? "Syncing…" : app.syncStatus.phase)
                                    .foregroundStyle(Theme.secondaryLabel)
                            }
                        } else if app.syncStatus.lastError != nil {
                            Text("Error")
                                .foregroundStyle(.red)
                        } else {
                            Text("Synced")
                                .foregroundStyle(.green)
                        }
                    }

                    HStack {
                        Text("Last Sync")
                        Spacer()
                        if let date = app.syncStatus.lastSyncAt ?? account.lastSyncAt {
                            Text(date.formatted(date: .numeric, time: .shortened))
                                .foregroundStyle(Theme.secondaryLabel)
                        } else {
                            Text("Never")
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }

                    Button {
                        isRefreshing = true
                        Task {
                            await app.refresh(force: true)
                            isRefreshing = false
                        }
                    } label: {
                        HStack {
                            Text("Re-sync with Server")
                                .foregroundStyle(Theme.label)
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(Theme.accent.opacity(0.15))
                                    .frame(width: 28, height: 28)
                                if isRefreshing || app.syncStatus.isSyncing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Sync Status")
                } footer: {
                    Text("If you notice data inconsistencies with your server please try to Re-Sync to refresh the local app database.")
                }

                Section("Library") {
                    HStack {
                        Text("Artists")
                        Spacer()
                        Text("\(counts.value.artists)")
                            .foregroundStyle(Theme.secondaryLabel)
                    }

                    HStack {
                        Text("Albums")
                        Spacer()
                        Text("\(counts.value.albums)")
                            .foregroundStyle(Theme.secondaryLabel)
                    }

                    HStack {
                        Text("Songs")
                        Spacer()
                        Text("\(counts.value.songs)")
                            .foregroundStyle(Theme.secondaryLabel)
                    }

                    HStack {
                        Text("Playlists")
                        Spacer()
                        Text("\(counts.value.playlists)")
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
            }
        }
        .observing(counts)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Manage Servers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(systemName: "plus", size: 36, tint: Theme.accent) {
                    showingAddServerSheet = true
                }
            }
        }
        .sheet(isPresented: $showingAddServerSheet) {
            LoginView()
        }
    }
}
