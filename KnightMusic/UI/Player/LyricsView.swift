import SwiftUI
import UIKit

/// Synced and unsynced lyrics viewer:
/// - Fetches lyrics via `library.lyrics(songId:)`, preferring synced lyrics
/// - Synced: 28pt semibold (iPad 34pt), active line in white, others white 35% with progressive blur
/// - Smooth auto-scroll keeps the active line at ~1/3 screen height
/// - Tap a line to seek directly to its timestamp (outside sync mode)
/// - Per-song sync adjuster panel with +/− controls and plain-language hint
/// - Tap-to-sync: in sync mode, tapping a line offsets lyrics so that line becomes current NOW
/// - Subtle offset badge when non-zero
/// - User scrolling pauses auto-scroll tracking for 3 seconds
/// - Unsynced: scrollable text; None: "No lyrics available"; Loading: ProgressView
struct LyricsView: View {
    let song: Song

    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player

    @State private var offsetStore = LyricsOffsetStore.shared
    @State private var lyricsList: [StructuredLyrics] = []
    @State private var identifiedLines: [IdentifiedLyricLine] = []
    @State private var startTimes: [Int] = []
    @State private var activeIndex: Int?
    @State private var isLoading = true
    @State private var isUserScrolling = false
    @State private var userScrollTask: Task<Void, Never>?
    @State private var isSyncMode = false
    @State private var showSyncedToast = false
    @State private var syncToastTrigger = 0
    @State private var syncedLineIndex: Int?

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var selectedLyrics: StructuredLyrics? {
        lyricsList.first(where: { $0.synced && !$0.line.isEmpty })
            ?? lyricsList.first(where: { !$0.line.isEmpty })
    }

    private func rebuildLyricsState() {
        guard let selected = selectedLyrics, !selected.line.isEmpty else {
            identifiedLines = []
            startTimes = []
            activeIndex = nil
            return
        }
        identifiedLines = LyricsTimeline.identifiedLines(for: selected)
        recomputeTimeline()
    }

    private func recomputeTimeline() {
        guard let selected = selectedLyrics, selected.synced, !selected.line.isEmpty else {
            startTimes = []
            activeIndex = nil
            return
        }
        let effectiveOffsetMs = offsetStore.effectiveOffset(serverOffset: selected.offset, songId: song.id)
        startTimes = LyricsTimeline.lineStartTimes(for: selected, effectiveOffsetMs: effectiveOffsetMs)
        let currentPlaybackMs = Int(player.currentTime * 1000)
        let newIndex = LyricsTimeline.activeLineIndex(for: currentPlaybackMs, in: startTimes)
        if activeIndex != newIndex {
            activeIndex = newIndex
        }
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
            isSyncMode = false
            showSyncedToast = false
            syncedLineIndex = nil
            activeIndex = nil
            lyricsList = await library.lyrics(songId: song.id)
            rebuildLyricsState()
            isLoading = false
        }
        .onChange(of: offsetStore.userOffset(for: song.id)) { _, _ in
            recomputeTimeline()
        }
    }

    @ViewBuilder
    private func syncedLyricsView(_ lyrics: StructuredLyrics) -> some View {
        let fontSize: CGFloat = isIPad ? 34 : 28
        let userOffset = offsetStore.userOffset(for: song.id)

        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                LyricsTimeTracker(startTimes: startTimes, activeIndex: $activeIndex)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: isIPad ? 22 : 16) {
                        // Top breathing room so the first line can rest at ~1/3 height
                        Color.clear.frame(height: 100)

                        ForEach(identifiedLines) { item in
                            let index = item.id
                            let line = item.line
                            let isActive = (index == activeIndex)
                            let distance = abs(index - (activeIndex ?? 0))
                            let blurRadius: CGFloat = distance > 2 ? min(CGFloat(distance - 2) * 1.0, 2.0) : 0
                            let opacity: Double = isActive ? 1.0 : 0.45

                            Button {
                                handleLineTap(index: index, line: line, lyrics: lyrics, proxy: proxy)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(line.value.isEmpty ? " " : line.value)
                                        .font(.system(size: fontSize, weight: .semibold))
                                        .foregroundStyle(Color.white.opacity(opacity))
                                        .blur(radius: blurRadius)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    if syncedLineIndex == index && showSyncedToast {
                                        syncedInlineBadge
                                    }
                                }
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
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.08),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { _ in
                            pauseAutoScroll(proxy: proxy)
                        }
                )
                .onAppear {
                    if let activeIndex {
                        proxy.scrollTo(activeIndex, anchor: UnitPoint(x: 0.5, y: 0.33))
                    }
                }
                .onChange(of: activeIndex) { _, newIndex in
                    guard let newIndex, !isUserScrolling else { return }
                    withAnimation(.smooth(duration: 0.5)) {
                        proxy.scrollTo(newIndex, anchor: UnitPoint(x: 0.5, y: 0.33))
                    }
                }

                // Top-right glass capsule control (shows offset badge subtly when non-zero)
                VStack {
                    HStack {
                        Spacer()
                        syncTopControl(userOffset: userOffset)
                    }
                    Spacer()
                }

                // Floating sync adjustment panel (presented in sync mode)
                if isSyncMode {
                    syncBottomPanel(userOffset: userOffset, lyrics: lyrics)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }

                // Toast banner for tap-to-sync feedback
                if showSyncedToast {
                    VStack {
                        syncedToastBanner
                            .padding(.top, 14)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(100)
                }
            }
            .task(id: syncToastTrigger) {
                guard syncToastTrigger > 0 else { return }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.3)) {
                    showSyncedToast = false
                    syncedLineIndex = nil
                }
            }
        }
    }

    private func handleLineTap(index: Int, line: StructuredLyrics.Line, lyrics: StructuredLyrics, proxy: ScrollViewProxy) {
        if isSyncMode {
            // Tap-to-sync: in sync mode, tapping a lyric line (instead of seeking) sets the offset so that line becomes current NOW:
            // userOffset = line.start - currentPlaybackMs - serverOffset; then exit sync mode with a success haptic and toast-like inline label "Synced".
            guard let start = line.start else { return }
            let currentPlaybackMs = Int(player.currentTime * 1000)
            let serverOffset = lyrics.offset ?? 0
            let newOffset = start - currentPlaybackMs - serverOffset
            offsetStore.setOffset(newOffset, for: song.id)
            recomputeTimeline()
            Haptics.success()

            syncedLineIndex = index
            showSyncedToast = true
            syncToastTrigger += 1

            // Stop user-scroll lock and center the newly synced line
            isUserScrolling = false
            userScrollTask?.cancel()
            userScrollTask = nil
            withAnimation(.smooth(duration: 0.5)) {
                proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.33))
            }

            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isSyncMode = false
            }
        } else {
            // Outside sync mode, tapping a line still seeks as today
            guard let start = line.start else { return }
            let effectiveOffsetMs = offsetStore.effectiveOffset(serverOffset: lyrics.offset, songId: song.id)
            let seekSec = max(0, Double(start - effectiveOffsetMs) / 1000.0)
            Haptics.impact(.light)
            player.seek(to: seekSec)
        }
    }

    private var syncedInlineBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text("Synced")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.accent, in: Capsule())
        .transition(.scale.combined(with: .opacity))
    }

    private var syncedToastBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Synced")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func syncTopControl(userOffset: Int) -> some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isSyncMode.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))

                if userOffset != 0 {
                    Text(offsetStore.formattedOffset(userOffset))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                } else {
                    Text("Sync")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(isSyncMode ? Theme.accent : (userOffset != 0 ? Theme.accent : Color.white.opacity(0.85)))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.trailing, Theme.margin)
        .padding(.top, 8)
    }

    private func syncBottomPanel(userOffset: Int, lyrics: StructuredLyrics) -> some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                // Plain-language hint
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text("Lyrics early? tap +")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.95))
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.35))
                    Text("Tap line to sync")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)

                // Adjuster capsule
                HStack(spacing: 2) {
                    syncAdjustButton(title: "−0.5s", deltaMs: -500)
                    syncAdjustButton(title: "−0.1s", deltaMs: -100)

                    // Current offset label
                    Text(offsetStore.formattedOffset(userOffset))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(userOffset == 0 ? Theme.secondaryLabel : Theme.accent)
                        .frame(minWidth: 56)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 2)

                    syncAdjustButton(title: "+0.1s", deltaMs: 100)
                    syncAdjustButton(title: "+0.5s", deltaMs: 500)

                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 3)

                    Button("Reset") {
                        offsetStore.resetOffset(for: song.id)
                        recomputeTimeline()
                        Haptics.impact(.light)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(userOffset == 0 ? Color.white.opacity(0.3) : Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                    .disabled(userOffset == 0)
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSyncMode = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 12)
    }

    private func syncAdjustButton(title: String, deltaMs: Int) -> some View {
        Button {
            offsetStore.adjustOffset(by: deltaMs, for: song.id)
            recomputeTimeline()
            Haptics.impact(.light)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func unsyncedLyricsView(_ lyrics: StructuredLyrics) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(identifiedLines) { item in
                    Text(item.line.value.isEmpty ? " " : item.line.value)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.margin + 8)
            .padding(.vertical, 24)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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

/// Tiny invisible observation point that is the ONLY view observing `player.currentTime`.
/// It updates `activeIndex` only when the active line actually changes.
private struct LyricsTimeTracker: View {
    @Environment(PlayerEngine.self) private var player
    let startTimes: [Int]
    @Binding var activeIndex: Int?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: player.currentTime) { _, newTime in
                updateIndex(currentTime: newTime)
            }
            .onAppear {
                updateIndex(currentTime: player.currentTime)
            }
            .onChange(of: startTimes) { _, _ in
                updateIndex(currentTime: player.currentTime)
            }
    }

    private func updateIndex(currentTime: TimeInterval) {
        guard !startTimes.isEmpty else {
            if activeIndex != nil {
                activeIndex = nil
            }
            return
        }
        let currentPlaybackMs = Int(currentTime * 1000)
        let newIndex = LyricsTimeline.activeLineIndex(for: currentPlaybackMs, in: startTimes)
        if activeIndex != newIndex {
            activeIndex = newIndex
        }
    }
}
