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

    init(initial: Value, database: LibraryDatabase?, fetch: @escaping @Sendable (Database) throws -> Value) {
        value = initial
        self.database = database
        self.fetch = fetch
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
                    isLoaded = true
                    error = nil
                    continue
                }

                guard newValue != value else { continue }
                pendingValue = newValue

                if coalesceTask == nil {
                    coalesceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled, let self else { return }
                        if let pending = self.pendingValue, pending != self.value {
                            self.value = pending
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
