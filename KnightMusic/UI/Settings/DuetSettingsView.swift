import SwiftUI

/// Settings → Duet: how Knight Music and Streamora share the app.
struct DuetSettingsView: View {
    @Environment(LookStore.self) private var looks
    @State private var settings = DuetSettings.shared
    @State private var duet = DuetCoordinator.shared
    @State private var confirmSignOut = false
    @State private var signingOut = false

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                Button {
                    DuetCoordinator.shared.switchTo(.movies)
                } label: {
                    Label("Open Streamora", systemImage: "film")
                        .foregroundStyle(Theme.accent)
                }
            } footer: {
                Text("Duet keeps Knight Music and Streamora in one app. Each side stays exactly where you left it while you use the other.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { looks.shakeAction == .switchWorld },
                    set: { looks.shakeAction = $0 ? .switchWorld : .off }
                )) {
                    Label("Shake to Switch", systemImage: "iphone.gen3.motion")
                }
                Toggle(isOn: $settings.confirmSwitch) {
                    Label("Ask Before Switching", systemImage: "questionmark.bubble")
                }
                Toggle(isOn: $settings.reopenLastSide) {
                    Label("Reopen Last Side", systemImage: "arrow.uturn.backward")
                }
            } header: {
                Text("Switching")
            } footer: {
                Text("While Streamora is open, a shake always offers the way back. You can also switch from the Home Screen quick action or the “Switch Duet Side” shortcut, which works with Back Tap (Accessibility → Touch → Back Tap).")
            }

            Section {
                Toggle(isOn: $settings.intermission) {
                    Label("Intermission", systemImage: "pause.circle")
                }
            } footer: {
                Text("Music always pauses when a movie starts. With Intermission on, it picks up where it stopped when the movie ends or when you switch back to Knight Music.")
            }

            Section {
                if duet.hasStage {
                    Button {
                        DuetCoordinator.shared.reloadStreamora()
                    } label: {
                        Label("Reload Streamora", systemImage: "arrow.clockwise")
                            .foregroundStyle(Theme.accent)
                    }
                }
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    HStack {
                        Label("Sign Out of Streamora", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        if signingOut { ProgressView() }
                    }
                }
                .disabled(signingOut)
            } header: {
                Text("Streamora")
            } footer: {
                Text("Streamora keeps your library and progress in your Google Drive. Signing out only clears it from this device.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground.ignoresSafeArea())
        .tint(Theme.accent)
        .navigationTitle("Duet")
        .confirmationDialog("Sign Out of Streamora", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                signingOut = true
                Task {
                    await DuetCoordinator.shared.clearStreamoraData()
                    signingOut = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will sign in to Google Drive again the next time you open Streamora.")
        }
    }
}
