import Foundation

/// Screenshot mode for CI (scripts/screens.sh): `-KMDemo YES -KMScreen <name>`.
/// Logs into demo.navidrome.org, waits for the first sync and exposes the requested screen. Inert in normal launches.
enum DebugLaunch {
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "KMDemo") }
    static var screen: String? { UserDefaults.standard.string(forKey: "KMScreen") }

    static let demoServer = URL(string: "https://demo.navidrome.org")!
    static let demoUser = "demo"
    static let demoPassword = "demo"

    /// Returns true if it handled startup (login + sync), so the caller skips its normal refresh.
    @MainActor @discardableResult
    static func applyIfNeeded(_ app: AppModel) async -> Bool {
        guard isDemo else { return false }
        app.debugScreen = screen
        if app.activeAccount == nil {
            do {
                try await app.login(name: "Navidrome Demo", addresses: [demoServer], username: demoUser, password: demoPassword)
            } catch {
                Log.app.error("demo login failed: \(error)")
                return true
            }
        } else {
            await app.refresh()
        }
        await app.waitForSync()
        return true
    }
}
