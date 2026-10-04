import SwiftUI

/// Settings → About: version check, SideStore install, and one-tap "add source" for SideStore-side updates.
struct UpdatesSection: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openURL) private var openURL
    @State private var message: String?

    var body: some View {
        Section {
            if let release = updates.available {
                Button {
                    Task {
                        if !(await updates.install(release)) {
                            message = "SideStore isn't installed. Opened the release page instead."
                            openURL(release.pageURL)
                        }
                    }
                } label: {
                    Label("Install \(release.version) with SideStore", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                if !release.notes.isEmpty {
                    Text(release.notes)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(6)
                }
            }

            Button {
                Task { await updates.check() }
            } label: {
                HStack {
                    Text("Check for Updates")
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    statusView
                }
            }
            .disabled(updates.status == .checking)

            Button {
                Task {
                    if !(await updates.addSourceToSideStore()) {
                        message = "SideStore isn't installed."
                    }
                }
            } label: {
                Text("Add Knight Music Source to SideStore")
                    .foregroundStyle(Theme.accent)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(message ?? "With the source added, SideStore lists new Knight Music versions and updates it from its own Updates screen. Your library, downloads and login are kept.")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch updates.status {
        case .checking:
            ProgressView()
        case .upToDate:
            Text("Up to date").foregroundStyle(Theme.secondaryLabel)
        case .failed(let reason):
            Text(reason).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
        case .idle:
            if updates.available != nil {
                Text("Update available").foregroundStyle(Theme.accent)
            }
        }
    }
}
