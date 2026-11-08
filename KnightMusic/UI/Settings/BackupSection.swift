import SwiftUI

/// Settings → Backup: settings saved on the Navidrome account, restored automatically on sign-in.
struct BackupSection: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingRestore = false

    private var backup: AccountBackupService { app.backup }

    var body: some View {
        @Bindable var backup = backup
        Section {
            Toggle("Back Up to Server", isOn: $backup.isEnabled)
                .tint(Theme.accent)

            if backup.isEnabled {
                HStack {
                    Text("Last Backup")
                        .foregroundStyle(Theme.label)
                    Spacer()
                    statusLabel
                }

                Button {
                    Task { await backup.sync(userInitiated: true) }
                } label: {
                    Text("Back Up Now")
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(backup.status == .working)

                Button {
                    confirmingRestore = true
                } label: {
                    Text("Restore from Server")
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(backup.status == .working)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Settings, looks, equalizer, Knight AI and Discord setup, Knight chats, server addresses and your downloaded songs are saved privately to your Navidrome account. After a reinstall, sign in and everything comes back.")
        }
        .confirmationDialog("Replace this device's settings with the backup on \(app.activeAccount?.name ?? "the server")?",
                            isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                Task { await backup.restoreNow() }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch backup.status {
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…").foregroundStyle(Theme.secondaryLabel)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(Color.red)
                .lineLimit(1)
        case .idle:
            if let date = backup.lastSyncedAt {
                Text(date, format: .relative(presentation: .named))
                    .foregroundStyle(Theme.secondaryLabel)
            } else {
                Text("Not yet").foregroundStyle(Theme.secondaryLabel)
            }
        }
    }
}
