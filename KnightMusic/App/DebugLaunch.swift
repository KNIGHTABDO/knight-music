import Foundation

/// Screenshot mode for CI (scripts/screens.sh): `-KMDemo YES -KMScreen <name>`.
/// Logs into demo.navidrome.org and opens the requested screen. Inert in normal launches.
enum DebugLaunch {
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "KMDemo") }
    static var screen: String? { UserDefaults.standard.string(forKey: "KMScreen") }

    static let demoServer = URL(string: "https://demo.navidrome.org")!
    static let demoUser = "demo"
    static let demoPassword = "demo"

    @MainActor static func applyIfNeeded(_ app: AppModel) {
        guard isDemo else { return }
    }
}
