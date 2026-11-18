import SwiftUI
import UIKit

/// Which events notify, plus the system permission (asked here, or sent to iOS Settings once denied).
struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let notifications = AppNotifications.shared

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.title2)
                        .foregroundStyle(notifications.canPost ? Color.green : Color.orange)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.body.weight(.semibold))
                        Text(statusDetail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                switch notifications.authorization {
                case .notDetermined:
                    Button("Allow Notifications") {
                        Task { await notifications.requestAuthorizationIfNeeded() }
                    }
                case .denied:
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                default:
                    EmptyView()
                }
            }

            Section {
                ForEach(AppNotifications.Kind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { notifications.isEnabled(kind) },
                        set: { notifications.setEnabled(kind, $0) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(kind.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: kind.systemImage)
                        }
                    }
                }
            } header: {
                Text("Notify Me About")
            } footer: {
                Text("Download progress also appears on the Lock Screen and in the Dynamic Island while a batch is running.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            // The user may have flipped the switch in iOS Settings and come back.
            if phase == .active { Task { await notifications.refreshAuthorization() } }
        }
    }

    private var statusSymbol: String {
        notifications.canPost ? "bell.badge.fill" : "bell.slash.fill"
    }

    private var statusTitle: String {
        switch notifications.authorization {
        case .notDetermined: "Not Set Up"
        case .denied: "Turned Off in iOS Settings"
        default: "Notifications On"
        }
    }

    private var statusDetail: String {
        switch notifications.authorization {
        case .notDetermined: "Allow notifications to hear when downloads finish and Knight replies."
        case .denied: "Duet can't alert you until notifications are allowed in iOS Settings."
        default: "Duet tells you when something finishes while you're away."
        }
    }
}
