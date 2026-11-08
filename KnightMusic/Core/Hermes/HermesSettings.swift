import Foundation
import SwiftUI

/// User settings for connecting to the Hermes agent server.
/// API key is securely stored in Keychain; Base URL is stored in UserDefaults.
@Observable
final class HermesSettings {
    static let defaultBaseURL = KnightDefaults.knightAIAddress
    private static let baseURLKey = "hermes_base_url"
    private static let keychainAccount = "hermes_api_key"

    var baseURLString: String {
        didSet {
            UserDefaults.standard.set(baseURLString, forKey: Self.baseURLKey)
        }
    }

    var baseURL: URL? {
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                Keychain.delete(account: Self.keychainAccount)
            } else {
                do {
                    try Keychain.set(apiKey, account: Self.keychainAccount)
                } catch {
                    Log.app.error("Failed to save Hermes API key to keychain: \(error)")
                }
            }
            if apiKey != oldValue { NotificationCenter.default.post(name: .knightBackupContentChanged, object: nil) }
        }
    }

    /// True when both a non-empty API key and a valid base URL are configured.
    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && baseURL != nil
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.baseURLKey)
        self.baseURLString = (saved?.isEmpty == false) ? saved! : Self.defaultBaseURL
        self.apiKey = Keychain.get(account: Self.keychainAccount) ?? ""
    }

    /// Re-reads the URL and key (after a backup restore wrote them).
    func reload() {
        let saved = UserDefaults.standard.string(forKey: Self.baseURLKey)
        baseURLString = (saved?.isEmpty == false) ? saved! : Self.defaultBaseURL
        apiKey = Keychain.get(account: Self.keychainAccount) ?? ""
    }

    func resetToDefaultURL() {
        baseURLString = Self.defaultBaseURL
    }
}
