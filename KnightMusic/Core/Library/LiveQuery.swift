import SwiftUI
import GRDB

/// A database query that keeps `value` current: it re-runs whenever the tables it reads change (sync,
/// mutations, downloads…). Reads happen off the main thread; only the assignment happens on it.
///
/// Usage in a view:
///     let albums = library.albums(sort: .recentlyAdded)      // cached instance, cheap to call in `body`
///     List(albums.value) { … }
///         .observing(albums)                                  // starts/stops with the view
@MainActor @Observable
final class LiveQuery<Value: Sendable & Equatable> {
    private(set) var value: Value
    /// False until the first database read has delivered (use to avoid flashing empty states).
    private(set) var isLoaded = false
    private(set) var error: Error?

    @ObservationIgnored private let database: LibraryDatabase?
    @ObservationIgnored private let fetch: @Sendable (Database) throws -> Value
    @ObservationIgnored private var pendingValue: Value?
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private var lastApplied: ContinuousClock.Instant?
    private static var coalesceWindow: Duration { .milliseconds(300) }

    init(initial: Value, database: LibraryDatabase?, fetch: @escaping @Sendable (Database) throws -> Value) {
        value = initial
        self.database = database
        self.fetch = fetch
    }

    /// One-shot read of the current rows, for callers that act once instead of observing (CarPlay, intents).
    /// `value` alone is only current while something is running the query.
    func load() async -> Value {
        guard let pool = database?.pool else { return value }
        do {
            return try await pool.read(fetch)
        } catch {
            Log.database.error("live query load failed: \(error)")
            return value
        }
    }

    /// Runs until the surrounding task is cancelled (e.g. the view disappears).
    func run() async {
        guard let pool = database?.pool else { return }
        let observation = ValueObservation.tracking(fetch).removeDuplicates()
        defer {
            coalesceTask?.cancel()
            coalesceTask = nil
            pendingValue = nil
        }
        var isFirstDelivery = true
        do {
            for try await newValue in observation.values(in: pool) {
                if isFirstDelivery {
                    isFirstDelivery = false
                    if newValue != value {
                        value = newValue
                    }
                    lastApplied = ContinuousClock.now
                    isLoaded = true
                    error = nil
                    continue
                }

                // The database is back at what is on screen (e.g. an optimistic write rolled back): drop the stale pending value.
                if newValue == value {
                    pendingValue = nil
                    continue
                }

                // Leading edge: the first change after a quiet period shows at once, so taps feel instant.
                // Bursts that follow are coalesced into one trailing update.
                let now = ContinuousClock.now
                if coalesceTask == nil, lastApplied.map({ now - $0 >= Self.coalesceWindow }) ?? true {
                    value = newValue
                    lastApplied = now
                    continue
                }

                pendingValue = newValue
                if coalesceTask == nil {
                    let wait = Self.coalesceWindow - (lastApplied.map { now - $0 } ?? .zero)
                    coalesceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: max(wait, .milliseconds(20)))
                        guard !Task.isCancelled, let self else { return }
                        if let pending = self.pendingValue, pending != self.value {
                            self.value = pending
                            self.lastApplied = ContinuousClock.now
                        }
                        self.pendingValue = nil
                        self.coalesceTask = nil
                    }
                }
            }
        } catch is CancellationError {
            // view went away
        } catch {
            self.error = error
            Log.database.error("LiveQuery failed: \(error)")
        }
    }
}

extension View {
    /// Keeps `query` running while this view is on screen.
    func observing<V: Sendable & Equatable>(_ query: LiveQuery<V>) -> some View {
        task(id: ObjectIdentifier(query)) { await query.run() }
    }
}
