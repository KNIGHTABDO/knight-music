import Foundation

/// A Navidrome server login. The password lives in the Keychain (see `AccountStore`).
struct ServerAccount: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var username: String
    /// Ordered by preference: LAN first, then Tailscale / public.
    var addresses: [URL]
    var createdAt: Date
    var lastSyncAt: Date?

    init(id: UUID = UUID(), name: String, username: String, addresses: [URL], createdAt: Date = Date(), lastSyncAt: Date? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.addresses = addresses
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
    }
}
