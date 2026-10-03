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

    func begin(phase: String, initial: Bool) {
        isSyncing = true
        isInitialSync = initial
        self.phase = phase
        fraction = 0
        lastError = nil
    }

    func update(phase: String? = nil, fraction: Double? = nil) {
        if let phase { self.phase = phase }
        if let fraction { self.fraction = max(self.fraction, min(1, fraction)) }
    }

    func finish(error: String?, completedAt: Date?) {
        isSyncing = false
        isInitialSync = false
        phase = ""
        fraction = error == nil ? 1 : fraction
        lastError = error
        if let completedAt { lastSyncAt = completedAt }
    }

    func reset() {
        isSyncing = false
        isInitialSync = false
        phase = ""
        fraction = 0
        lastSyncAt = nil
        lastError = nil
    }

    func restore(from database: LibraryDatabase) async {
        if let raw = await database.stateValue(SyncKey.lastSyncAt), let t = TimeInterval(raw) {
            lastSyncAt = Date(timeIntervalSince1970: t)
        }
    }
}

enum SyncKey {
    static let lastScan = "lastScan"
    static let lastLibrarySync = "lastLibrarySync"
    static let lastSyncAt = "lastSyncAt"
}
