import SwiftUI

/// What the app is fetching right now: user downloads plus songs saved ahead for playback / AutoMix.
@MainActor
struct TransferSummary {
    struct Download {
        let id: String
        let status: DownloadStatus
    }

    var downloads: [Download]
    var cache: [CacheTransfer]

    init(downloads manager: DownloadManager, player: PlayerEngine) {
        downloads = manager.statuses
            .filter { $0.value.state == .queued || $0.value.state == .downloading }
            .map { Download(id: $0.key, status: $0.value) }
            .sorted { ($0.status.state == .downloading ? 0 : 1, $0.id) < ($1.status.state == .downloading ? 0 : 1, $1.id) }
        let downloading = Set(downloads.map(\.id))
        cache = player.cacheTransfers.filter { !downloading.contains($0.songId) }
    }

    var count: Int { downloads.count + cache.count }
    var isEmpty: Bool { count == 0 }

    /// Average progress of what is actually transferring (queued items don't drag it down).
    var fraction: Double {
        let running = downloads.filter { $0.status.state == .downloading }.map(\.status.progress)
            + cache.compactMap(\.fraction)
        guard !running.isEmpty else { return 0 }
        return running.reduce(0, +) / Double(running.count)
    }

    var firstId: String? { downloads.first?.id ?? cache.first?.songId }
}

/// Floating glass pill above the tab bar while anything downloads; opens the transfers sheet.
struct TransfersIndicator: ViewModifier {
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library
    @State private var isShowingSheet = false
    @State private var firstTitle: String?

    func body(content: Content) -> some View {
        let summary = TransferSummary(downloads: downloads, player: player)
        content
            .overlay(alignment: .bottom) {
                if !summary.isEmpty {
                    pill(summary)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: summary.isEmpty)
            .task(id: summary.firstId) {
                guard let id = summary.firstId else { return }
                firstTitle = await library.song(id: id)?.title
            }
            .sheet(isPresented: $isShowingSheet) { TransfersSheet() }
    }

    private func pill(_ summary: TransferSummary) -> some View {
        Button {
            Haptics.impact(.light)
            isShowingSheet = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(summary.fraction, 0.04))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth, value: summary.fraction)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.label)
                }
                .frame(width: 22, height: 22)
                Text(title(summary))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                if summary.fraction > 0 {
                    Text("\(Int(summary.fraction * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondaryLabel)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: 300)
        .accessibilityLabel("\(summary.count) transfers, \(Int(summary.fraction * 100)) percent")
    }

    private func title(_ summary: TransferSummary) -> String {
        if summary.count > 1 { return "Downloading \(summary.count) songs" }
        return firstTitle.map { "Downloading \u{201C}\($0)\u{201D}" } ?? "Downloading"
    }
}

extension View {
    /// Adds the floating "downloading" pill (and its transfers sheet) to a tab's root.
    func transfersIndicator() -> some View { modifier(TransfersIndicator()) }
}

/// Every transfer in progress with its own progress bar.
struct TransfersSheet: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [String: Song] = [:]

    var body: some View {
        let summary = TransferSummary(downloads: downloads, player: player)
        NavigationStack {
            List {
                if summary.isEmpty {
                    Section {
                        Label("Nothing is downloading", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
                if !summary.downloads.isEmpty {
                    Section {
                        ForEach(summary.downloads, id: \.id) { item in
                            row(songId: item.id,
                                detail: item.status.state == .queued ? "Waiting" : sizeText(item.status),
                                fraction: item.status.state == .downloading ? item.status.progress : nil,
                                waiting: item.status.state == .queued)
                                .swipeActions {
                                    Button("Cancel", role: .destructive) { downloads.cancel(songId: item.id) }
                                }
                        }
                    } header: {
                        Text("Downloads")
                    } footer: {
                        Text("Saved for offline listening. Swipe to cancel.")
                    }
                }
                if !summary.cache.isEmpty {
                    Section {
                        ForEach(summary.cache) { item in
                            row(songId: item.songId,
                                detail: item.urgent ? "For the next AutoMix blend" : (item.fraction == nil ? "Waiting" : "Up next"),
                                fraction: item.fraction,
                                waiting: item.fraction == nil,
                                badge: item.urgent ? "AutoMix" : nil)
                        }
                    } header: {
                        Text("Saving for Playback")
                    } footer: {
                        Text("Upcoming songs are saved ahead so they start instantly and AutoMix can blend them.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: summary.downloads.map(\.id) + summary.cache.map(\.songId)) {
                let ids = summary.downloads.map(\.id) + summary.cache.map(\.songId)
                let missing = ids.filter { songs[$0] == nil }
                guard !missing.isEmpty else { return }
                for song in await library.songs(ids: missing) { songs[song.id] = song }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(songId: String, detail: String, fraction: Double?, waiting: Bool, badge: String? = nil) -> some View {
        let song = songs[songId]
        return HStack(spacing: 12) {
            ArtworkView(coverArt: song?.coverArt, pointSize: 44, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(song?.title ?? "Loading\u{2026}")
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.15), in: Capsule())
                    }
                }
                if waiting {
                    ProgressView().progressViewStyle(.linear).tint(Theme.secondaryLabel)
                } else {
                    ProgressView(value: fraction ?? 0).progressViewStyle(.linear).tint(Theme.accent)
                }
                Text("\(song?.artist ?? "") \u{2022} \(detail)\(fraction.map { " \u{2022} \(Int($0 * 100))%" } ?? "")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func sizeText(_ status: DownloadStatus) -> String {
        status.bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(status.bytes), countStyle: .file) : "Downloading"
    }
}
