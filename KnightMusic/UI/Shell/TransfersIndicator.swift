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
    var hasStarted: Bool { downloads.contains { $0.status.bytes > 0 } || cache.contains { $0.fraction != nil } }

    /// Average progress of what is actually transferring (queued items don't drag it down).
    var fraction: Double {
        let running = downloads.filter { $0.status.progress > 0 }.map(\.status.progress)
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
    @Environment(AppModel.self) private var app
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
            .task(id: "\(app.accountActivation)|\(summary.firstId ?? "")") {
                firstTitle = nil
                guard let id = summary.firstId else { return }
                let song = await library.song(id: id)
                if !Task.isCancelled { firstTitle = song?.title }
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
        .accessibilityLabel(title(summary))
    }

    private func title(_ summary: TransferSummary) -> String {
        if summary.cache.isEmpty && summary.downloads.allSatisfy({ $0.status.progress == 1 }) {
            return "Verifying downloads"
        }
        if !summary.hasStarted {
            let scheduled = summary.downloads.contains { $0.status.state == .downloading }
            return scheduled ? "Downloads scheduled" : "Downloads queued"
        }
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
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [String: Song] = [:]
    @State private var loadedAccountActivation: Int?

    var body: some View {
        let summary = TransferSummary(downloads: downloads, player: player)
        let issues = downloads.statuses.filter {
            $0.value.state == .failed || $0.value.state == .needsRetry || $0.value.state == .recoveryBlocked
        }.sorted { $0.key < $1.key }
        let ids = summary.downloads.map(\.id) + summary.cache.map(\.songId) + issues.map(\.key)
        let activation = app.accountActivation
        NavigationStack {
            List {
                if summary.isEmpty && issues.isEmpty {
                    Section {
                        Label("Nothing is downloading", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
                if !summary.downloads.isEmpty {
                    Section {
                        ForEach(summary.downloads, id: \.id) { item in
                            row(songId: item.id,
                                detail: downloadDetail(item.status),
                                fraction: item.status.progress > 0 && item.status.progress < 1 ? item.status.progress : nil,
                                isTransferring: item.status.bytes > 0 && item.status.progress == 0)
                                .swipeActions {
                                    Button("Cancel", role: .destructive) { downloads.cancel(songId: item.id) }
                                }
                        }
                    } header: {
                        Text("Downloads")
                    } footer: {
                        Text("Songs are playable offline after verification. Swipe to cancel.")
                    }
                }
                if !issues.isEmpty {
                    Section("Download Recovery") {
                        ForEach(issues.map(\.key), id: \.self) { id in
                            row(songId: id, detail: downloads.status(for: id)?.errorMessage ?? "Couldn’t download this song.",
                                fraction: nil)
                        }
                        if issues.contains(where: { $0.value.state == .failed }) {
                            Button("Retry Failed Downloads") { downloads.retryFailed() }
                        }
                        if issues.contains(where: { $0.value.state == .needsRetry }) {
                            Button("Save New Offline Copies") { downloads.retryFailed(includeLegacy: true) }
                        }
                        if issues.contains(where: { $0.value.state == .recoveryBlocked }) {
                            Button("Retry Download Recovery") { downloads.retryRecovery() }
                        }
                    }
                }
                if !summary.cache.isEmpty {
                    Section {
                        ForEach(summary.cache) { item in
                            row(songId: item.songId,
                                detail: item.urgent ? "For the next AutoMix blend" : (item.fraction == nil ? "Waiting" : "Up next"),
                                fraction: item.fraction,
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
            .task(id: [String(activation)] + ids) {
                if loadedAccountActivation != activation {
                    songs.removeAll()
                    loadedAccountActivation = activation
                }
                let missing = ids.filter { songs[$0] == nil }
                guard !missing.isEmpty else { return }
                let fetched = await library.songs(ids: missing)
                guard !Task.isCancelled, app.accountActivation == activation else { return }
                for song in fetched { songs[song.id] = song }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(songId: String, detail: String, fraction: Double?, isTransferring: Bool = false, badge: String? = nil) -> some View {
        let song = loadedAccountActivation == app.accountActivation ? songs[songId] : nil
        return HStack(spacing: 12) {
            ArtworkView(coverArt: song?.coverArt, pointSize: 44, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(song?.title ?? "Song")
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
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.accent)
                } else if isTransferring {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func downloadDetail(_ status: DownloadStatus) -> String {
        if status.state == .queued {
            if app.settings.offlineMode == .manual && app.settings.manualOfflineEnabled { return "Offline mode is on" }
            if app.isOffline { return "Waiting for your server" }
            return "Queued in Knight Music"
        }
        if status.bytes == 0 {
            return !app.settings.downloadOverCellular && app.network.isCellular ? "Waiting for Wi-Fi" : "Scheduled with iOS"
        }
        if status.progress == 1 { return "Verifying audio" }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(status.bytes), countStyle: .file)
        return "Downloading · \(bytes)"
    }
}
