import Foundation
import UIKit

extension Notification.Name {
    /// Posted by stores whose data lives outside UserDefaults (Knight chats, Keychain secrets) when it changes.
    static let knightBackupContentChanged = Notification.Name("knightBackupContentChanged")
}

/// Keeps the device's settings in sync with a backup stored on the Navidrome account, so a SideStore reinstall,
/// a new device or a wiped app comes back exactly as it was after signing in.
///
/// Rules: a fresh install (never synced with this account) takes the server copy. Afterwards, a newer server copy
/// is applied when this device has no unsynced changes; otherwise this device's state is uploaded.
/// Nothing is ever uploaded unless the server was read successfully first, so a failed read can't overwrite a backup.
@MainActor @Observable
final class AccountBackupService {
    enum Status: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastSyncedAt: Date?
    /// A one-line message for the shell to show as a toast; `noticeID` changes with each one.
    private(set) var notice: String?
    private(set) var noticeID = UUID()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled); if isEnabled { scheduleSync(after: 0.5) } }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var runningSync: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Downloads other devices reported in the last backup read, kept so uploads don't erase them.
    @ObservationIgnored private var otherDevicesDownloads: [String: [String]] = [:]

    private enum Keys {
        static let enabled = "backup.enabled"
        static let deviceId = "backup.deviceId"
        /// Before pending downloads were kept per account; read once as the active account's.
        static let legacyPendingDownloads = "backup.pendingDownloads"
        static func pendingDownloads(_ id: UUID) -> String { "backup.pendingDownloads.\(id.uuidString)" }
        static func state(_ id: UUID) -> String { "backup.state.\(id.uuidString)" }
    }

    /// Per-account record of the last successful sync.
    private struct SyncState: Codable {
        var fingerprint: String
        var remoteUpdatedAt: Date
        var syncedAt: Date
    }

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    }

    private var isActive: Bool { isEnabled && !DebugLaunch.isDemo }

    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: Keys.deviceId) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Keys.deviceId)
        return id
    }

    func start(app: AppModel) {
        self.app = app
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let changed: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.localStateChanged() }
        }
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: changed))
        observers.append(center.addObserver(forName: .knightBackupContentChanged, object: nil, queue: .main, using: changed))
        refreshLastSyncedAt()
    }

    func sessionDidChange() {
        refreshLastSyncedAt()
    }

    private func localStateChanged() {
        guard !applying, isActive, app?.session == .ready else { return }
        scheduleSync(after: 4, onlyIfChanged: true)
    }

    /// Coalesces bursts of changes (sliders, typing) into one sync. `onlyIfChanged` skips the server round trip
    /// when nothing backed up differs from the last sync (most UserDefaults writes are caches and bookkeeping).
    func scheduleSync(after seconds: Double, onlyIfChanged: Bool = false) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if onlyIfChanged, !self.hasUnsyncedChanges() { return }
            await self.sync()
        }
    }

    private func hasUnsyncedChanges() -> Bool {
        guard let account = app?.activeAccount else { return false }
        guard let state = loadState(account.id) else { return true }
        return captureLocal(account: account).fingerprint != state.fingerprint
    }

    /// Called when the app goes to the background: finish an upload even if the user leaves.
    func flushInBackground() {
        guard isActive, app?.session == .ready else { return }
        debounceTask?.cancel()
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "KnightBackup") {
            MainActor.assumeIsolated { token.end() }
        }
        Task {
            await self.sync()
            token.end()
        }
    }

    // MARK: - Sync

    /// Reads the server copy, then either applies it or uploads local changes. Safe to call often.
    func sync(userInitiated: Bool = false) async {
        guard isActive else { return }
        if let running = runningSync {
            syncAgain = true
            await running.value
            return
        }
        let task = Task { await self.performSync(userInitiated: userInitiated) }
        runningSync = task
        await task.value
        runningSync = nil
        if syncAgain {
            syncAgain = false
            scheduleSync(after: 1)
        }
    }

    private func performSync(userInitiated: Bool) async {
        guard let app, app.session == .ready, let client = app.client, let account = app.activeAccount else { return }
        status = .working
        do {
            let (playlists, remote) = try await fetch(client: client, username: account.username)
            if let remote { otherDevicesDownloads = remote.content.downloads.filter { $0.key != BackupSnapshot.deviceKind } }
            let state = loadState(account.id)
            let local = captureLocal(account: account)
            let localFingerprint = local.fingerprint

            // "Different", not "newer": the stamps come from each device's own clock, so a device whose clock runs
            // behind would otherwise never be believed.
            if let remote, abs(remote.updatedAt.timeIntervalSince(state?.remoteUpdatedAt ?? .distantPast)) > 0.001 {
                let neverSynced = state == nil
                if neverSynced || state?.fingerprint == localFingerprint {
                    apply(remote, accountId: account.id, freshInstall: neverSynced)
                    if neverSynced { postNotice("Restored your settings from \(account.name)") }
                    status = .idle
                    return
                }
                Log.app.info("Backup: server and device both changed; keeping this device's settings")
                postNotice("Settings changed on two devices. This device's copy was kept.")
            }

            if remote == nil || state?.fingerprint != localFingerprint || userInitiated {
                var outgoing = local
                // Secrets this device couldn't open stay on the server unless this device has its own.
                outgoing.undecryptedSecrets = (remote?.content.undecryptedSecrets ?? [:]).filter { local.secrets[$0.key] == nil }
                try await upload(outgoing, playlists: playlists, client: client, account: account)
                if userInitiated { postNotice("Settings backed up to \(account.name)") }
            }
            status = .idle
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
            Log.app.error("Backup sync failed: \(error)")
            if userInitiated { postNotice("Backup failed: \(error.localizedDescription)") }
        }
    }

    /// Replaces this device's settings with the server copy, on request.
    func restoreNow() async {
        guard isActive, let app, let client = app.client, let account = app.activeAccount else { return }
        status = .working
        do {
            let (_, remote) = try await fetch(client: client, username: account.username)
            guard let remote else {
                status = .idle
                postNotice("No backup on \(account.name) yet")
                return
            }
            apply(remote, accountId: account.id, freshInstall: false)
            status = .idle
            postNotice("Restored your settings from \(account.name)")
        } catch {
            status = .failed(error.localizedDescription)
            Log.app.error("Backup restore failed: \(error)")
            postNotice("Restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Login

    /// Reads the backup with the login probe client, before the account is stored, so the app opens already restored.
    func fetchForLogin(client: SubsonicClient, username: String) async -> BackupEnvelope? {
        guard isActive else { return nil }
        do {
            return try await withThrowingTaskGroup(of: BackupEnvelope?.self) { group in
                group.addTask { try await Self.readRemote(client: client, username: username).envelope }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw URLError(.timedOut)
                }
                let result = try await group.next() ?? nil
                group.cancelAll()
                return result
            }
        } catch {
            Log.app.error("Backup read at sign-in failed (will retry after sync): \(error)")
            return nil
        }
    }

    /// Applies a backup read at sign-in to the newly added account.
    func applyAtLogin(_ remote: BackupEnvelope, accountId: UUID, accountName: String) {
        otherDevicesDownloads = remote.content.downloads.filter { $0.key != BackupSnapshot.deviceKind }
        apply(remote, accountId: accountId, freshInstall: loadState(accountId) == nil)
        postNotice("Restored your settings from \(accountName)")
    }

    // MARK: - Downloads

    /// After a library sync, re-downloads what this device had before a reinstall (songs must be in the mirror).
    func resumePendingDownloads() async {
        guard let app, let accountId = app.activeAccount?.id else { return }
        adoptLegacyPendingDownloads(for: accountId)
        let key = Keys.pendingDownloads(accountId)
        guard let pending = UserDefaults.standard.stringArray(forKey: key), !pending.isEmpty else { return }
        let missing = pending.filter { !app.downloads.isDownloaded($0) && app.downloads.status(for: $0) == nil }
        let songs = await app.library.songs(ids: missing)
        if !songs.isEmpty {
            app.downloads.download(songs: songs)
            Log.app.info("Backup: re-downloading \(songs.count) songs from before the reinstall")
        }
        // Runs after a full library sync, so songs not found are gone from the server: stop looking for them.
        UserDefaults.standard.removeObject(forKey: key)
        let gone = missing.count - songs.count
        if gone > 0 { Log.app.info("Backup: \(gone) previously downloaded songs are no longer on the server") }
    }

    // MARK: - Internals

    /// Songs still being re-downloaded after a restore (or not yet looked up) stay in this device's backup list,
    /// so the first upload doesn't shrink it to whatever happened to finish already.
    private func backedUpDownloadIds(accountId: UUID?) -> Set<String> {
        var ids = app?.downloads.wantedSongIds ?? []
        if let accountId, let pending = UserDefaults.standard.stringArray(forKey: Keys.pendingDownloads(accountId)) {
            ids.formUnion(pending)
        }
        return ids
    }

    private func adoptLegacyPendingDownloads(for accountId: UUID) {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.stringArray(forKey: Keys.legacyPendingDownloads) else { return }
        if defaults.stringArray(forKey: Keys.pendingDownloads(accountId)) == nil {
            defaults.set(legacy, forKey: Keys.pendingDownloads(accountId))
        }
        defaults.removeObject(forKey: Keys.legacyPendingDownloads)
    }

    private func captureLocal(account: ServerAccount) -> BackupContent {
        BackupSnapshot.capture(
            account: account,
            downloadedSongIds: backedUpDownloadIds(accountId: account.id),
            otherDevicesDownloads: otherDevicesDownloads
        )
    }

    private func apply(_ remote: BackupEnvelope, accountId: UUID, freshInstall: Bool) {
        applying = true
        defer { applying = false }
        BackupSnapshot.apply(remote.content)
        if !remote.content.undecryptedSecrets.isEmpty {
            postNotice("Some saved keys in the backup couldn't be unlocked (password changed?). This device's copies were kept.")
        }
        if freshInstall, let ids = remote.content.downloads[BackupSnapshot.deviceKind], !ids.isEmpty {
            UserDefaults.standard.set(ids, forKey: Keys.pendingDownloads(accountId))
        }
        mergeAddresses(remote.content.serverAddresses, accountId: accountId)
        app?.reloadRestoredSettings()
        // Fingerprint what the device holds now, so the next change is recognised as local.
        let account = app?.accounts.accounts.first { $0.id == accountId }
        let fingerprint = BackupSnapshot.capture(
            account: account,
            downloadedSongIds: backedUpDownloadIds(accountId: accountId),
            otherDevicesDownloads: otherDevicesDownloads
        ).fingerprint
        saveState(SyncState(fingerprint: fingerprint, remoteUpdatedAt: remote.updatedAt, syncedAt: Date()), accountId: accountId)
        Log.app.info("Backup: applied server copy from \(remote.deviceName) (\(remote.updatedAt))")
    }

    private func mergeAddresses(_ addresses: [String], accountId: UUID) {
        guard let app, var account = app.accounts.accounts.first(where: { $0.id == accountId }) else { return }
        let extra = addresses.compactMap(URL.init(string:)).filter { url in
            url.scheme?.hasPrefix("http") == true && !account.addresses.contains(url)
        }
        guard !extra.isEmpty else { return }
        account.addresses.append(contentsOf: extra)
        app.accounts.update(account)
    }

    private func upload(_ content: BackupContent, playlists: [Playlist], client: SubsonicClient, account: ServerAccount) async throws {
        let now = Date()
        let envelope = BackupEnvelope(
            updatedAt: now,
            deviceId: deviceId,
            deviceName: UIDevice.current.model,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            content: content
        )
        let comment = try BackupCodec.encode(envelope, key: BackupCodec.secretKey(password: client.password, username: account.username))
        // Newest backup playlist is the one we read; remove stray duplicates (two devices creating at once).
        let ordered = playlists.sorted { ($0.changed ?? .distantPast) > ($1.changed ?? .distantPast) }
        let id: String
        if let existing = ordered.first {
            id = existing.id
            for duplicate in ordered.dropFirst() { try? await client.deletePlaylist(id: duplicate.id) }
        } else {
            id = try await client.createPlaylist(name: BackupCodec.playlistName).0.id
        }
        try await client.updatePlaylist(id: id, name: BackupCodec.playlistName, comment: comment, isPublic: false)
        saveState(SyncState(fingerprint: content.fingerprint, remoteUpdatedAt: now, syncedAt: now), accountId: account.id)
        Log.app.info("Backup: uploaded \(comment.utf8.count / 1024) KB to \(account.name)")
    }

    private func fetch(client: SubsonicClient, username: String) async throws -> (playlists: [Playlist], envelope: BackupEnvelope?) {
        try await Self.readRemote(client: client, username: username)
    }

    private nonisolated static func readRemote(client: SubsonicClient, username: String) async throws -> (playlists: [Playlist], envelope: BackupEnvelope?) {
        let playlists = try await client.getBackupPlaylists().filter { $0.isOwned(by: username) }
        let key = BackupCodec.secretKey(password: client.password, username: username)
        let newest = playlists
            .compactMap { BackupCodec.decode($0.comment, key: key) }
            .max { $0.updatedAt < $1.updatedAt }
        return (playlists, newest)
    }

    private func loadState(_ accountId: UUID) -> SyncState? {
        guard let data = UserDefaults.standard.data(forKey: Keys.state(accountId)) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    private func saveState(_ state: SyncState, accountId: UUID) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Keys.state(accountId))
        }
        if accountId == app?.activeAccount?.id || app?.activeAccount == nil { lastSyncedAt = state.syncedAt }
    }

    private func refreshLastSyncedAt() {
        lastSyncedAt = app?.activeAccount.flatMap { loadState($0.id)?.syncedAt }
    }

    func clearNotice() { notice = nil }

    private func postNotice(_ message: String) {
        notice = message
        noticeID = UUID()
    }
}

/// Ends a background task exactly once, whether the work finishes or the system expires it first.
@MainActor
private final class BackgroundTaskToken {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
