import SwiftUI
import UIKit

/// Synced and unsynced lyrics viewer:
/// - Fetches lyrics via `library.lyrics(songId:)`, preferring synced lyrics
/// - Synced: 28pt semibold (iPad 34pt), active line in white, others white 35% with progressive blur
/// - Smooth auto-scroll keeps the active line at ~1/3 screen height
/// - Tap a line to seek directly to its timestamp
/// - User scrolling pauses auto-scroll tracking for 3 seconds
/// - Unsynced: scrollable text; None: "No lyrics available"; Loading: ProgressView
struct LyricsView: View {
    let song: Song

    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player

    @State private var lyricsList: [StructuredLyrics] = []
    @State private var isLoading = true
    @State private var isUserScrolling = false
    @State private var userScrollTask: Task<Void, Never>?

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var selectedLyrics: StructuredLyrics? {
        lyricsList.first(where: { $0.synced && !$0.line.isEmpty })
            ?? lyricsList.first(where: { !$0.line.isEmpty })
    }

    private var activeIndex: Int? {
        guard let selected = selectedLyrics, selected.synced, !selected.line.isEmpty else { return nil }
        let offsetMs = selected.offset ?? 0
        let currentMs = Int(player.currentTime * 1000) + offsetMs

        var foundIndex: Int? = nil
        for (index, line) in selected.line.enumerated() {
            if let start = line.start {
                if start <= currentMs {
                    foundIndex = index
                } else {
                    break
                }
            }
        }
        return foundIndex
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let selected = selectedLyrics, !selected.line.isEmpty {
                if selected.synced {
                    syncedLyricsView(selected)
                } else {
                    unsyncedLyricsView(selected)
                }
            } else {
                Text("No lyrics available")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: song.id) {
            isLoading = true
            lyricsList = await library.lyrics(songId: song.id)
            isLoading = false
        }
    }

    @ViewBuilder
    private func syncedLyricsView(_ lyrics: StructuredLyrics) -> some View {
        let fontSize: CGFloat = isIPad ? 34 : 28
        let offsetMs = lyrics.offset ?? 0

        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: isIPad ? 22 : 16) {
                    // Top breathing room so the first line can rest at ~1/3 height
                    Color.clear.frame(height: 100)

                    ForEach(Array(lyrics.line.enumerated()), id: \.offset) { index, line in
                        let isActive = (index == activeIndex)
                        let distance = abs(index - (activeIndex ?? 0))
                        let blurRadius: CGFloat = distance > 2 ? min(CGFloat(distance - 2) * 1.2, 3.5) : 0
                        let opacity: Double = isActive ? 1.0 : 0.35

                        Button {
                            if let start = line.start {
                                let seekSec = max(0, Double(start - offsetMs) / 1000.0)
                                Haptics.impact(.light)
                                player.seek(to: seekSec)
                            }
                        } label: {
                            Text(line.value.isEmpty ? " " : line.value)
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(opacity))
                                .blur(radius: blurRadius)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }

                    // Bottom padding so the last line can also scroll to ~1/3 height
                    Color.clear.frame(height: 240)
                }
                .padding(.horizontal, Theme.margin + 8)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in
                        pauseAutoScroll(proxy: proxy)
                    }
            )
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex, !isUserScrolling else { return }
                withAnimation(.smooth(duration: 0.5)) {
                    proxy.scrollTo(newIndex, anchor: UnitPoint(x: 0.5, y: 0.33))
                }
            }
        }
    }

    @ViewBuilder
    private func unsyncedLyricsView(_ lyrics: StructuredLyrics) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lyrics.line.enumerated()), id: \.offset) { _, line in
                    Text(line.value.isEmpty ? " " : line.value)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.margin + 8)
            .padding(.vertical, 24)
        }
    }

    private func pauseAutoScroll(proxy: ScrollViewProxy) {
        isUserScrolling = true
        userScrollTask?.cancel()
        userScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isUserScrolling = false
            if let index = activeIndex {
                withAnimation(.smooth(duration: 0.5)) {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.33))
                }
            }
        }
    }
}
