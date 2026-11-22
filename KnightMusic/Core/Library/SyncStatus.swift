import Foundation

/// Observable progress of the library sync, shown in Settings and during first login.
@MainActor @Observable
final class SyncStatus {
    private(set) var isSyncing = false
    /// True while the very first sync into an empty database is running.
    private(set) var isInitialSync = false
    private(set) var phase = ""
    private(set) var fraction: Double = 0
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    /// True when `lastError` came from failing to reach the server (network, timeout, HTTP failure),
    /// as opposed to e.g. bad credentials or a response the app couldn't read.
    private(set) var isTransportFailure = false

    /// Only the engine that last called `begin` may publish; a torn-down account's run is ignored.
    @ObservationIgnored private var currentToken: UUID?

    func begin(phase: String, initial: Bool, token: UUID? = nil) {
        currentToken = token
        isSyncing = true
        isInitialSync = initial
        self.phase = phase
        fraction = 0
        lastError = nil
        isTransportFailure = false
    }

    func update(phase: String? = nil, fraction: Double? = nil, token: UUID? = nil) {
        guard token == nil || token == currentToken else { return }
        if let phase { self.phase = phase }
        if let fraction { self.fraction = max(self.fraction, min(1, fraction)) }
    }

    func finish(error: String?, completedAt: Date?, transportFailure: Bool = false, token: UUID? = nil) {
        guard token == nil || token == currentToken else { return }
        isSyncing = false
        isInitialSync = false
        phase = ""
        fraction = error == nil ? 1 : fraction
        lastError = error
        isTransportFailure = error != nil && transportFailure
        if let completedAt { lastSyncAt = completedAt }
    }

    func reset() {
        currentToken = nil
        isSyncing = false
        isInitialSync = false
        phase = ""
        fraction = 0
        lastSyncAt = nil
        lastError = nil
        isTransportFailure = false
    }

    func restore(from database: LibraryDatabase) async {
        if let raw = await database.stateValue(SyncKey.lastSyncAt), let t = TimeInterval(raw) {
            lastSyncAt = Date(timeIntervalSince1970: t)
        }
    }
}

/// What one SyncEngine uses to talk to the shared SyncStatus.
struct SyncStatusHandle: Sendable {
    let status: SyncStatus
    let token = UUID()

    func begin(phase: String, initial: Bool) async { await status.begin(phase: phase, initial: initial, token: token) }
    func update(phase: String? = nil, fraction: Double? = nil) async { await status.update(phase: phase, fraction: fraction, token: token) }
    func finish(error: String?, completedAt: Date?, transportFailure: Bool = false) async {
        await status.finish(error: error, completedAt: completedAt, transportFailure: transportFailure, token: token)
    }
}

enum SyncKey {
    static let lastScan = "lastScan"
    static let lastLibrarySync = "lastLibrarySync"
    static let lastSyncAt = "lastSyncAt"
}
