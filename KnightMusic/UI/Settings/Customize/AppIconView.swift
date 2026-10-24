import SwiftUI

/// Home-screen icon gallery. Some icons unlock with listening time; one is hidden.
struct AppIconView: View {
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui: UIState?
    @State private var icons = AppIconManager.shared
    @State private var secretTaps = 0
    @State private var revealing = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 18)]

    var body: some View {
        let replay = library.replay(ReplayPeriod(scope: .allTime))
        let hours = replay.value.seconds / 3600

        ScrollView {
            VStack(spacing: 24) {
                currentHeader
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(visibleIcons) { icon in
                        tile(icon, unlocked: icons.isUnlocked(icon, listenedHours: hours), hours: hours)
                    }
                }
                .padding(.horizontal, 16)
                if !icons.supportsAlternates {
                    Text("This device doesn't allow changing the app icon.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
        }
        .background(Theme.groupedBackground.ignoresSafeArea())
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .observing(replay)
    }

    private var visibleIcons: [AppIconChoice] {
        AppIconChoice.all.filter { $0.unlock != .secret || icons.secretFound }
    }

    private var current: AppIconChoice {
        AppIconChoice.all.first { $0.id == icons.currentId } ?? AppIconChoice.all[0]
    }

    /// The current icon, large. Tapping it seven times reveals the hidden one.
    private var currentHeader: some View {
        VStack(spacing: 10) {
            Image(current.previewImage)
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .rotation3DEffect(.degrees(revealing ? 360 : 0), axis: (x: 0, y: 1, z: 0))
                .onTapGesture(perform: tapCurrent)
                .accessibilityLabel("Current icon: \(current.name)")
            Text(current.name).font(.headline)
            Text(current.caption).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func tile(_ icon: AppIconChoice, unlocked: Bool, hours: Int) -> some View {
        let selected = icon.id == icons.currentId
        return Button {
            choose(icon, unlocked: unlocked, hours: hours)
        } label: {
            VStack(spacing: 6) {
                Image(icon.previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .saturation(unlocked ? 1 : 0)
                    .blur(radius: unlocked ? 0 : 3)
                    .overlay {
                        if !unlocked {
                            Image(systemName: "lock.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 3)
                            .padding(-4)
                    }
                Text(icon.name)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                if case .hours(let needed) = icon.unlock, !unlocked {
                    Text("\(hours) / \(needed) h")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ icon: AppIconChoice, unlocked: Bool, hours: Int) {
        guard unlocked else {
            if case .hours(let needed) = icon.unlock {
                ui?.showToast("Listen \(needed - hours) more hours to unlock \(icon.name)")
            }
            Haptics.warning()
            return
        }
        Task {
            do {
                try await icons.setIcon(icon)
                Haptics.success()
            } catch {
                Log.app.error("Changing app icon failed: \(error)")
                ui?.showToast("Couldn't change the icon")
            }
        }
    }

    private func tapCurrent() {
        guard !icons.secretFound else { return }
        secretTaps += 1
        Haptics.impact(secretTaps >= 5 ? .heavy : .light)
        guard secretTaps >= 7 else { return }
        withAnimation(.smooth(duration: 0.9)) {
            revealing = true
            icons.secretFound = true
        }
        Haptics.success()
        ui?.showToast("A hidden icon appeared 👀")
    }
}
