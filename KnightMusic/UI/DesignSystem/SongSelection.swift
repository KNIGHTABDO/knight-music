import SwiftUI

/// Multi-select state for a song list ("Select" in the toolbar). Rows toggle membership instead of playing.
@MainActor
@Observable
final class SongSelection {
    var isActive = false
    var ids: Set<String> = []

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func begin() { ids = []; isActive = true }
    func end() { ids = []; isActive = false }

    /// Selected songs in list order.
    func songs(in list: [Song]) -> [Song] { list.filter { ids.contains($0.id) } }
}

/// Leading check circle shown on rows while selecting.
struct SelectionCheck: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryLabel)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }
}

extension View {
    /// Puts a check circle in front of the row while `selection` is active.
    func selectable(_ id: String, in selection: SongSelection) -> some View {
        HStack(spacing: 12) {
            if selection.isActive {
                SelectionCheck(isSelected: selection.ids.contains(id))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            self
        }
        .animation(.snappy, value: selection.isActive)
    }

    /// Toolbar "Select"/"Done" toggle plus the floating glass action bar for the selected songs.
    func songSelection(_ selection: SongSelection, songs: [Song]) -> some View {
        modifier(SongSelectionChrome(selection: selection, songs: songs))
    }
}

private struct SongSelectionChrome: ViewModifier {
    let selection: SongSelection
    let songs: [Song]

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if selection.isActive {
                        Button("Done", systemImage: "checkmark") {
                            withAnimation(.snappy) { selection.end() }
                        }
                        .buttonStyle(.glassProminent)
                    } else {
                        Button("Select", systemImage: "checklist") {
                            Haptics.selection()
                            withAnimation(.snappy) { selection.begin() }
                        }
                        .disabled(songs.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selection.isActive {
                    SongSelectionBar(selection: selection, songs: songs)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: selection.isActive)
    }
}

/// Glass action bar: select all, play, play next, add to queue, add to playlist, download, love.
struct SongSelectionBar: View {
    let selection: SongSelection
    let songs: [Song]

    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui: UIState?
    @Namespace private var glass

    var body: some View {
        let picked = selection.songs(in: songs)
        let allSelected = !songs.isEmpty && picked.count == songs.count
        VStack(spacing: 8) {
            Text(picked.isEmpty ? "Select Songs" : "\(picked.count) Selected")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryLabel)
                .contentTransition(.numericText())
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    barButton(allSelected ? "Deselect All" : "Select All",
                              allSelected ? "circle.dashed" : "checkmark.circle", enabled: !songs.isEmpty) {
                        selection.ids = allSelected ? [] : Set(songs.map(\.id))
                    }
                    barButton("Play", "play.fill", enabled: !picked.isEmpty) {
                        player.play(picked, startAt: 0, shuffle: false)
                        selection.end()
                    }
                    barButton("Play Next", "text.line.first.and.arrowtriangle.forward", enabled: !picked.isEmpty) {
                        player.enqueue(picked, next: true)
                        ui?.showToast("Playing \(picked.count) Next")
                        selection.end()
                    }
                    barButton("Add to Queue", "text.append", enabled: !picked.isEmpty) {
                        player.enqueue(picked, next: false)
                        ui?.showToast("Added \(picked.count) to Queue")
                        selection.end()
                    }
                    barButton("Add to Playlist", "text.badge.plus", enabled: !picked.isEmpty) {
                        ui?.playlistPicker = PlaylistPickerRequest(songs: picked)
                        selection.end()
                    }
                    barButton("Download", "arrow.down.circle", enabled: !picked.isEmpty) {
                        downloads.download(songs: picked.filter { !downloads.isDownloaded($0.id) })
                        ui?.showToast("Downloading \(picked.count) Songs")
                        selection.end()
                    }
                    barButton("Love", "heart", enabled: !picked.isEmpty) {
                        let ids = picked.filter { $0.starred == nil }.map(\.id)
                        selection.end()
                        Task {
                            for id in ids {
                                guard (try? await library.setStarred(.song, id: id, true)) != nil else { return }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 8)
        .sensoryFeedback(.selection, trigger: picked.count)
    }

    private func barButton(_ title: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title)
        .help(title)
    }
}
