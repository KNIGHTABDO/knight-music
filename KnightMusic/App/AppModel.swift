import SwiftUI

/// Root of the object graph. Owns every long-lived service and wires them together.
@MainActor @Observable
final class AppModel {
    public static var shared: AppModel?

    enum SessionState: Equatable {
        case loggedOut
        case connecting
        case ready
        case failed(String)
    }

    let settings = AppSettings()
    let network = NetworkMonitor()
    let accounts = AccountStore()
    let addressResolver = AddressResolver()
    let syncStatus = SyncStatus()
    let library = LibraryRepository()
    let downloads = DownloadManager()
    let artwork = AnimatedArtworkService()
    let player: PlayerEngine
    let hermes = HermesService()
    let updates = UpdateChecker()
    @ObservationIgnored private var autoMixShowcase: AutoMixShowcase?
    let autoDownloader = AutoDownloader()

    private(set) var session: SessionState = .loggedOut

    /// Client for the active account/address; nil when logged out.
    private(set) var client: SubsonicClient?
    /// Library mirror of the active account; nil when logged out.
    private(set) var database: LibraryDatabase?
    private(set) var activeAccount: ServerAccount?
    /// False when the last reachability check (ping on any address) failed.
    private(set) var serverReachable = true {
        didSet {
            guard serverReachable != oldValue else { return }
            if serverReachable {
                stopReachabilityRecovery()
                // Back from an outage, whatever noticed it: catch the library up (SyncEngine dedupes overlapping syncs).
                Log.api.info("Server reachable again")
                Task { await self.refresh() }
            } else {
                startReachabilityRecovery()
            }
        }
    }
    /// Bumps on every client/database change; observe it from views that must rebuild on account switch.
    private(set) var sessionRevision = 0
    /// Screen requested via `-KMScreen` in screenshot mode; the shell routes on it.
    var debugScreen: String?

    @ObservationIgnored let playbackServices = PlaybackServices()
    @ObservationIgnored var lastConfiguredDatabaseId: ObjectIdentifier?
    @ObservationIgnored private var syncEngine: SyncEngine?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var observers: [@MainActor (AppModel) -> Void] = []
    @ObservationIgnored private var syncTask: Task<Bool, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var lastRecheck = Date.distantPast
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init() {
        player = PlayerEngine()
        network.onChange = { [weak self] in self?.networkChanged() }
        library.isOfflineProvider = { [weak self] in self?.isOffline ?? false }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.library.dropCaches() }
        }
        restoreSession()
        installServiceWiring()
        hermes.configure(app: self, library: library, artwork: artwork)
        WidgetBridge.shared.start(app: self)
    }


    // MARK: - Offline

    /// Manual switch, or (automatic) no network / server unreachable.
    var isOffline: Bool {
        switch settings.offlineMode {
        case .manual: return settings.manualOfflineEnabled
        case .automatic: return !network.isConnected || !serverReachable
        }
    }

    // MARK: - Session hooks

    /// Registers a callback fired whenever the client or database changes (login, logout, account switch,
    /// address change). PlayerEngine / ArtworkLoader / DownloadManager are configured through this.
    func addSessionObserver(fireImmediately: Bool = true, _ observer: @escaping @MainActor (AppModel) -> Void) {
        observers.append(observer)
        if fireImmediately { observer(self) }
    }

    private func notifySessionChanged() {
        sessionRevision += 1
        for observer in observers { observer(self) }
    }

    // MARK: - Launch

    /// Idempotent launch entry: the phone UI, a CarPlay scene and background launches (remote play, Siri) all call it.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task { await start() }
    }

    func start() async {
        started = true
        updates.checkIfDue()
        if autoMixShowcase == nil { autoMixShowcase = AutoMixShowcase(app: self) }
        autoMixShowcase?.start()
        let handled = await DebugLaunch.applyIfNeeded(self)
        if !handled { await refresh() }
    }

    func handleForeground() {
        if started {
            updates.checkIfDue()
            autoMixShowcase?.refreshIfDue()
        }
        guard started, session == .ready else { return }
        if !serverReachable {
            Task { await reresolveAddress() }
            return
        }
        if let lastSync = syncStatus.lastSyncAt, Date().timeIntervalSince(lastSync) < 180 {
            return
        }
        Task { await refresh() }
    }

    func scheduleBackgroundSync() {
        guard session == .ready else { return }
        BackgroundSync.schedule()
    }

    /// Entry point for BGAppRefreshTask; may run before any UI exists.
    func performBackgroundSync() async -> Bool {
        // A background launch can fire the task before the session finished opening the library.
        startIfNeeded()
        for _ in 0..<50 where session != .ready {
            if case .loggedOut = session, accounts.active == nil { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard session == .ready, let engine = syncEngine else { return false }
        await reresolveAddress()
        guard network.isConnected else { return false }
        return await withTaskCancellationHandler {
            await engine.sync()
        } onCancel: {
            Task { await engine.cancel() }
        }
    }

    func cancelBackgroundSync() {
        guard let engine = syncEngine else { return }
        Task { await engine.cancel() }
    }

    // MARK: - Sync

    /// Re-resolves the server address, then runs an incremental sync (or a forced full one).
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        guard syncEngine != nil, let account = activeAccount else { return false }
        let task = Task { () -> Bool in
            await self.reresolveAddress(maxAge: 20)
            // Even if the quick probe failed, try the real sync (15s timeout): a slow link is not an offline one.
            guard self.network.isConnected, let engine = self.syncEngine else { return false }
            let ok = await engine.sync(force: force)
            self.serverReachable = ok || self.serverReachable && !self.syncStatusIndicatesTransportFailure
            if ok {
                self.accounts.touchSync(account.id)
                // Siri resolves album/artist/playlist names from these parameters; refresh them once the mirror changed.
                KnightMusicShortcuts.updateParameters()
                if let database = self.database {
                    Task.detached(priority: .utility) { await SpotlightIndexer.reindex(database: database) }
                }
            }
            return ok
        }
        syncTask = task
        return await task.value
    }

    /// Pull-to-refresh. Safe to call from `.refreshable`: view cancellation doesn't cancel the sync.
    func pullToRefresh() async {
        await refresh()
    }

    /// Waits for whatever sync is currently running (used by screenshot mode).
    func waitForSync() async {
        _ = await syncTask?.value
    }

    // MARK: - Address resolution

    /// Waits for an in-progress address resolution to complete (max `timeout` seconds).
    func waitForAddressResolution(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while addressResolver.isResolving, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @discardableResult
    func reresolveAddress(maxAge: TimeInterval = 0) async -> URL? {
        guard let account = activeAccount, let password else { return nil }
        if maxAge > 0, serverReachable, network.isConnected,
           let last = addressResolver.lastResolvedAt, Date().timeIntervalSince(last) < maxAge {
            return client?.baseURL
        }
        guard network.isConnected else {
            serverReachable = false
            return nil
        }
        var url = await addressResolver.resolve(account: account, password: password)
        if url == nil, network.isConnected, activeAccount?.id == account.id {
            // The quick probe favours the preferred (LAN) address; a cold Tailscale/cellular link can need longer.
            // Only a slow probe that also fails means the server is really unreachable.
            url = await addressResolver.resolve(account: account, password: password, timeout: 8)
        }
        guard activeAccount?.id == account.id else { return nil }
        if let url {
            serverReachable = true
            if url != client?.baseURL {
                installClient(baseURL: url)
                notifySessionChanged()
            }
            return url
        } else {
            serverReachable = false
            return nil
        }
    }

    private var syncStatusIndicatesTransportFailure: Bool {
        guard let message = syncStatus.lastError else { return false }
        return message.contains("Could not reach") || message.contains("did not respond") || message.contains("not connected")
    }

    private func networkChanged() {
        player.networkDidChange()
        downloads.networkDidChange()
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reresolveAddress()
            await self.refresh()
        }
    }

    /// Called (off the main actor) when a request failed after retries: re-check addresses soon.
    private func transportErrorSeen() {
        guard session == .ready, recheckTask == nil, Date().timeIntervalSince(lastRecheck) > 8 else { return }
        lastRecheck = Date()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.reresolveAddress()
            self?.recheckTask = nil
        }
    }

    /// The server can drop (home internet blip) while this device's network stays the same, so nothing else would
    /// re-check it: keep pinging with backoff until it answers, then catch the library up.
    private func startReachabilityRecovery() {
        guard recoveryTask == nil, session == .ready else { return }
        recoveryTask = Task { [weak self] in
            var delay = 2
            while true {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 10)
                guard !Task.isCancelled, let self else { return }
                guard self.network.isConnected else { continue }
                // Success flips `serverReachable`, which cancels this loop and starts the catch-up sync.
                if await self.reresolveAddress() != nil { return }
            }
        }
    }

    private func stopReachabilityRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    // MARK: - Accounts

    /// Validates the server (pings each address in order), stores the account and starts the first sync.
    func login(name: String, addresses: [URL], username: String, password: String) async throws {
        let previous = session
        if previous != .ready { session = .connecting }
        var added: ServerAccount?
        do {
            var reachable: URL?
            var lastError: Error?
            for address in addresses {
                let probe = SubsonicClient(baseURL: address, username: username, password: password, requestTimeout: 8, maxAttempts: 1)
                do {
                    try await probe.ping()
                    reachable = address
                    break
                } catch let error as SubsonicError {
                    if case .server = error { throw error }
                    lastError = error
                } catch {
                    lastError = error
                }
            }
            guard let reachable else { throw lastError ?? SubsonicError.noReachableServer }

            let host = reachable.host ?? "Navidrome"
            let account = ServerAccount(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name, username: username, addresses: addresses)
            try accounts.add(account, password: password)
            added = account
            accounts.setActive(account.id)
            addressResolver.remember(reachable, for: account.id)
            try activate(account)
            Log.app.info("logged in to \(account.name) via \(reachable.absoluteString)")
            syncTask = Task { await self.refresh(force: true) }
        } catch {
            if let added {
                accounts.remove(added.id)
                addressResolver.forget(accountId: added.id)
                LibraryDatabase.deleteFiles(for: added.id)
                if let previousActive = accounts.active { accounts.setActive(previousActive.id) }
            }
            session = previous == .connecting ? .loggedOut : previous
            Log.app.error("login failed: \(error)")
            throw error
        }
    }

    func switchAccount(id: UUID) {
        guard id != activeAccount?.id, let account = accounts.accounts.first(where: { $0.id == id }) else { return }
        accounts.setActive(id)
        do {
            try activate(account)
            syncTask = Task { await self.refresh() }
        } catch {
            session = .failed(error.localizedDescription)
            Log.app.error("switchAccount failed: \(error)")
        }
    }

    /// Signs out of the active server and deletes its local mirror (downloads included).
    func logout() {
        guard let id = activeAccount?.id else { return }
        removeAccount(id: id)
    }

    func removeAccount(id: UUID) {
        let wasActive = activeAccount?.id == id
        if wasActive { teardownSession() }
        accounts.remove(id)
        addressResolver.forget(accountId: id)
        LibraryDatabase.deleteFiles(for: id)
        Task { await SpotlightIndexer.removeAll(accountId: id) }
        guard wasActive else { return }
        if let next = accounts.active {
            do {
                try activate(next)
                syncTask = Task { await self.refresh() }
            } catch {
                session = .failed(error.localizedDescription)
            }
        } else {
            session = .loggedOut
            notifySessionChanged()
        }
    }

    // MARK: - Session lifecycle

    private func restoreSession() {
        guard let account = accounts.active else { return }
        do {
            try activate(account)
        } catch {
            session = .failed(error.localizedDescription)
            Log.app.error("restore failed: \(error)")
        }
    }

    private func activate(_ account: ServerAccount) throws {
        guard let password = accounts.password(for: account.id) else {
            throw SubsonicError.server(code: 40, message: "Saved password is missing. Please sign in again.")
        }
        let database = try LibraryDatabase(accountId: account.id)
        let cached = addressResolver.cachedAddress(for: account.id)
        guard let address = cached.flatMap({ account.addresses.contains($0) ? $0 : nil }) ?? account.addresses.first else {
            throw SubsonicError.invalidURL
        }

        teardownSession()
        activeAccount = account
        self.password = password
        self.database = database
        serverReachable = true
        installClient(baseURL: address)
        if let client {
            syncEngine = SyncEngine(database: database, client: client, status: syncStatus)
        }
        library.configure(database: database, client: client, syncEngine: syncEngine)
        session = .ready
        notifySessionChanged()
        Task { await syncStatus.restore(from: database) }
    }

    private func installClient(baseURL: URL) {
        guard let account = activeAccount, let password else { return }
        let new = SubsonicClient(
            baseURL: baseURL,
            username: account.username,
            password: password,
            onTransportError: { [weak self] in
                Task { @MainActor in self?.transportErrorSeen() }
            }
        )
        client = new
        library.configure(database: database, client: new, syncEngine: syncEngine)
        if let engine = syncEngine {
            Task { await engine.setClient(new) }
        }
    }

    private func teardownSession() {
        networkTask?.cancel()
        stopReachabilityRecovery()
        recheckTask?.cancel()
        recheckTask = nil
        syncTask?.cancel()
        if let engine = syncEngine { Task { await engine.cancel() } }
        syncEngine = nil
        client = nil
        database?.close()
        database = nil
        password = nil
        activeAccount = nil
        library.configure(database: nil, client: nil, syncEngine: nil)
        syncStatus.reset()
    }
}
