import SwiftUI

/// Toasts, Navidrome import progress and the "already in your library" question. Applied to the shell and to
/// the full player (which covers the shell), showing in whichever is on screen.
struct ShellBannersPresenter: ViewModifier {
    var insidePlayer: Bool

    @Environment(UIState.self) private var ui
    @Environment(PlayerEngine.self) private var player

    private var imports: NavidromeImportCenter { .shared }
    private var isActive: Bool { ui.isPlayerPresented == insidePlayer }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isActive {
                    VStack(spacing: 8) {
                        if let toast = ui.toast {
                            ToastCapsule(text: toast)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if let job = imports.visibleJob {
                            ImportProgressPill(job: job) {
                                if let song = job.importedSong, job.state == .done {
                                    player.play([song], startAt: 0, shuffle: false)
                                    ui.isPlayerPresented = true
                                    return
                                }
                                guard let conversationId = job.conversationId else { return }
                                ui.isPlayerPresented = false
                                ui.knightConversation = conversationId
                                ui.selectedTab = .knight
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 20)
                    .animation(.smooth, value: ui.toast)
                    .animation(.smooth, value: imports.visibleJob)
                }
            }
            .confirmationDialog(
                imports.confirmation.map { $0.kind == .same ? "Already in Your Library" : "Similar Song in Your Library" } ?? "",
                isPresented: Binding(
                    get: { isActive && imports.confirmation != nil },
                    set: { if !$0 { imports.confirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: imports.confirmation
            ) { confirmation in
                Button("Keep the One I Have", role: .cancel) {
                    imports.resolve(confirmation, addAnyway: false)
                }
                Button(confirmation.kind == .same ? "Add Anyway" : "Add This Version Too") {
                    imports.resolve(confirmation, addAnyway: true)
                }
            } message: { confirmation in
                Text(message(for: confirmation))
            }
    }

    private func message(for confirmation: NavidromeImportCenter.Confirmation) -> String {
        let list = confirmation.matches.prefix(4).map { song in
            [song.title, song.artist, song.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        }.joined(separator: "\n")
        let lead = confirmation.kind == .same
            ? "You already have \u{201C}\(confirmation.song.title)\u{201D}:"
            : "You have another version of \u{201C}\(confirmation.song.title)\u{201D}:"
        return lead + "\n" + list
    }
}

private struct ToastCapsule: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Live status of the current "Add to Navidrome" job; tapping it opens the Knight conversation doing the work.
private struct ImportProgressPill: View {
    let job: NavidromeImportCenter.Job
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ArtworkView(coverArt: job.song.coverArt, pointSize: 32, cornerRadius: 6)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.song.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(job.stage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 4)
                statusIcon
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: 420)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .done:
            Label("Play", systemImage: "play.fill")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 14, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 20))
        default:
            ProgressView().controlSize(.small)
        }
    }
}
