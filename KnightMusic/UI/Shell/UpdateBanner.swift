import SwiftUI

/// Floating glass capsule announcing a newer release; tap installs through SideStore, × hides it for that version.
struct UpdateBanner: View {
    let release: UpdateChecker.Release

    @Environment(UpdateChecker.self) private var updates
    @Environment(UIState.self) private var ui
    @Environment(\.openURL) private var openURL

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Haptics.impact(.light)
                    Task {
                        if !(await updates.install(release)) {
                            ui.showToast("SideStore not found. Opening the release page.")
                            openURL(release.pageURL)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("Knight Music \(release.version) available")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                        Text("Update")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    withAnimation(.smooth) { updates.dismissBanner() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Dismiss update")
            }
        }
    }
}
