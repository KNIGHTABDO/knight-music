import BackgroundTasks
import Foundation

/// BGAppRefreshTask glue. `register` must run during app launch (KnightMusicApp.init).
enum BackgroundSync {
    static let identifier = "com.knightabdo.knightmusic.sync"

    /// - Parameters:
    ///   - work: performs an incremental sync, returns success.
    ///   - cancel: called if iOS expires the task.
    static func register(work: @escaping @Sendable () async -> Bool, cancel: @escaping @Sendable () -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let job = Task {
                let ok = await work()
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = {
                cancel()
                job.cancel()
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.sync.warning("could not schedule background sync: \(error.localizedDescription)")
        }
    }
}
