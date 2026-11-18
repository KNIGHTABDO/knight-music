import ActivityKit
import Foundation
import GRDB
import Observation
import UIKit

/// Turns DownloadManager's per-song statuses into a "batch": a Live Activity while songs are in flight, and a
/// notification when the batch ends while the app is in the background (or when songs failed).
/// A batch starts when a song becomes queued/downloading and ends when none are left.
@MainActor
final class TransferActivityController {
    static let shared = TransferActivityController()

    private weak var downloads: DownloadManager?
    private var database: DatabaseReader?
    private var batch: Set<String> = []
    private var batchStart = Date()
    private var titles: [String: (title: String, artist: String?)] = [:]
    private var activity: Activity<TransferActivityAttributes>?
    private var lastState: TransferActivityAttributes.ContentState?
    private var refreshTask: Task<Void, Never>?
    private var lastPush = Date.distantPast
    private var batchNumber = 0

    /// A Live Activity is worth it for real batches; a single quick download only gets the in-app pill.
    private let minimumSongsForActivity = 2
    private let singleSongGrace: TimeInterval = 4
    /// ActivityKit throttles frequent updates; one a second is smooth enough for a progress bar.
    private let pushInterval: TimeInterval = 1

    private init() {}

    func attach(_ downloads: DownloadManager, database: DatabaseReader?) {
        self.database = database
        guard self.downloads !== downloads else { return }
        self.downloads = downloads
        endStaleActivities()
        observe()
        scheduleRefresh()
    }

    private func observe() {
        guard let downloads else { return }
        withObservationTracking {
            _ = downloads.statuses
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
                self?.observe()
            }
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        let wait = max(0, pushInterval - Date().timeIntervalSince(lastPush))
        refreshTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self else { return }
            self.refreshTask = nil
            await self.refresh()
        }
    }

    private func refresh() async {
        guard let downloads else { return }
        lastPush = Date()
        let statuses = downloads.statuses
        let active = statuses.filter { $0.value.state == .queued || $0.value.state == .downloading }.map(\.key)
        if batch.isEmpty {
            guard !active.isEmpty else { return }
            batchStart = Date()
            batchNumber += 1
            titles = [:]
            Task { await AppNotifications.shared.requestAuthorizationIfNeeded() }
        }
        batch.formUnion(active)
        // Cancelled songs leave the status table; they no longer belong to the batch.
        batch = batch.filter { statuses[$0] != nil }
        guard !batch.isEmpty else {
            await endActivity(final: nil)
            return
        }

        var completed = 0, failed = 0, inFlight = 0.0
        var current: String?
        for id in batch {
            guard let status = statuses[id] else { continue }
            switch status.state {
            case .completed: completed += 1
            case .failed, .needsRetry, .recoveryBlocked: failed += 1
            case .downloading:
                inFlight += min(max(status.progress, 0), 1)
                if current == nil || status.progress > (statuses[current!]?.progress ?? 0) { current = id }
            case .queued: break
            }
        }
        let total = batch.count
        let finished = completed + failed == total
        await loadTitles(for: current.map { [$0] } ?? [])
        let state = TransferActivityAttributes.ContentState(
            completed: completed,
            failed: failed,
            total: total,
            fraction: total == 0 ? 0 : min(1, (Double(completed + failed) + inFlight) / Double(total)),
            currentTitle: current.flatMap { titles[$0]?.title },
            currentArtist: current.flatMap { titles[$0]?.artist },
            isFinished: finished
        )

        if finished {
            await endActivity(final: state)
            notifyFinished(state, failedIds: batch.filter { id in
                guard let s = statuses[id]?.state else { return false }
                return s == .failed || s == .needsRetry || s == .recoveryBlocked
            })
            batch = []
            return
        }

        let worthAnActivity = total >= minimumSongsForActivity || Date().timeIntervalSince(batchStart) > singleSongGrace
        guard worthAnActivity else {
            // Re-check after the grace period even if nothing changes.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.singleSongGrace ?? 4))
                self?.scheduleRefresh()
            }
            return
        }
        guard state != lastState else { return }
        lastState = state
        await pushActivity(state)
    }

    private func loadTitles(for ids: [String]) async {
        let missing = ids.filter { titles[$0] == nil }
        guard !missing.isEmpty, let database else { return }
        let songs = (try? await database.read { db in try LibraryQueries.songs(db, ids: missing) }) ?? []
        for song in songs { titles[song.id] = (song.title, song.artist) }
    }

    private func pushActivity(_ state: TransferActivityAttributes.ContentState) async {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
        if let activity, activity.activityState == .active {
            await activity.update(content)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !DebugLaunch.isDemo else { return }
        do {
            activity = try Activity.request(attributes: TransferActivityAttributes(startedAt: batchStart),
                                            content: content, pushType: nil)
        } catch {
            Log.app.error("Download Live Activity failed to start: \(error.localizedDescription)")
        }
    }

    private func endActivity(final state: TransferActivityAttributes.ContentState?) async {
        lastState = nil
        guard let activity else { return }
        self.activity = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        // Leave the summary up briefly so a glance at the lock screen still shows the outcome.
        await activity.end(content, dismissalPolicy: state == nil ? .immediate : .after(Date().addingTimeInterval(state!.failed > 0 ? 15 * 60 : 90)))
    }

    /// Activities left over from a previous run (the app was killed mid-batch) would otherwise stay frozen.
    private func endStaleActivities() {
        for stale in Activity<TransferActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func notifyFinished(_ state: TransferActivityAttributes.ContentState, failedIds: Set<String>) {
        let appActive = UIApplication.shared.applicationState == .active
        // In the app the pill already shows success; failures always deserve a durable record.
        guard !appActive || state.failed > 0 else { return }
        let id = "downloads.batch.\(batchNumber)"
        if state.failed > 0 {
            AppNotifications.shared.post(
                .downloads, id: id,
                title: state.headline,
                body: state.failed == 1 ? "One song couldn't be downloaded. Tap Retry to try again."
                    : "\(state.failed) songs couldn't be downloaded. Tap Retry to try again.",
                category: AppNotifications.Category.downloadsFailed,
                info: [AppNotifications.Key.route: "downloads"],
                relevance: 0.8)
        } else {
            let names = batch.compactMap { titles[$0]?.title }.prefix(2)
            let body = state.completed == 1 ? (names.first.map { "“\($0)” is ready to play offline." } ?? "Ready to play offline.")
                : "Your songs are ready to play offline."
            AppNotifications.shared.post(
                .downloads, id: id, title: state.headline, body: body,
                category: AppNotifications.Category.downloads,
                info: [AppNotifications.Key.route: "downloads"], relevance: 0.4)
        }
    }
}
