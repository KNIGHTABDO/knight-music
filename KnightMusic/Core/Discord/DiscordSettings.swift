import Foundation
import SwiftUI

/// Settings for Discord Rich Presence integration.
/// Token is saved securely in the device Keychain; preferences are in UserDefaults.
@Observable
final class DiscordSettings {
    private static let enabledKey = "discord_rpc_enabled"
    private static let showArtworkKey = "discord_rpc_show_artwork"
    private static let clearOnPauseKey = "discord_rpc_clear_on_pause"
    private static let activityNameKey = "discord_rpc_activity_name"
    private static let applicationIdKey = "discord_rpc_application_id"
    private static let keychainAccount = "discord_user_token"

    static let defaultApplicationId = "1140767928610979862"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    var showArtwork: Bool {
        didSet { UserDefaults.standard.set(showArtwork, forKey: Self.showArtworkKey) }
    }

    var clearOnPause: Bool {
        didSet { UserDefaults.standard.set(clearOnPause, forKey: Self.clearOnPauseKey) }
    }

    var activityName: String {
        didSet { UserDefaults.standard.set(activityName, forKey: Self.activityNameKey) }
    }

    var applicationId: String {
        didSet { UserDefaults.standard.set(applicationId, forKey: Self.applicationIdKey) }
    }

    var effectiveApplicationId: String {
        let trimmed = applicationId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultApplicationId : trimmed
    }

    var token: String {
        didSet {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Keychain.delete(account: Self.keychainAccount)
            } else {
                do {
                    try Keychain.set(trimmed, account: Self.keychainAccount)
                } catch {
                    Log.app.error("Failed to save Discord token to Keychain: \(error)")
                }
            }
        }
    }

    var state: DiscordConnectionState = .disconnected

    var isConfigured: Bool {
        isEnabled && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.showArtwork = UserDefaults.standard.object(forKey: Self.showArtworkKey) as? Bool ?? true
        self.clearOnPause = UserDefaults.standard.object(forKey: Self.clearOnPauseKey) as? Bool ?? true
        self.activityName = UserDefaults.standard.string(forKey: Self.activityNameKey) ?? "Knight Music"
        self.applicationId = UserDefaults.standard.string(forKey: Self.applicationIdKey) ?? Self.defaultApplicationId
        self.token = Keychain.get(account: Self.keychainAccount) ?? ""
    }
}
