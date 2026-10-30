import Foundation

enum DiscordConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(username: String)
    case error(String)

    var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case .connected(let username):
            return "Connected as @\(username)"
        case .error(let message):
            return message
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct DiscordActivity: Codable, Equatable, Sendable {
    var name: String
    var type: Int
    var application_id: String?
    var details: String?
    var state: String?
    var timestamps: Timestamps?
    var assets: Assets?

    struct Timestamps: Codable, Equatable, Sendable {
        var start: Int64?
        var end: Int64?

        init(start: Int64? = nil, end: Int64? = nil) {
            self.start = start
            self.end = end
        }
    }

    struct Assets: Codable, Equatable, Sendable {
        var large_image: String?
        var large_text: String?
        var small_image: String?
        var small_text: String?

        init(large_image: String? = nil, large_text: String? = nil, small_image: String? = nil, small_text: String? = nil) {
            self.large_image = large_image
            self.large_text = large_text
            self.small_image = small_image
            self.small_text = small_text
        }
    }

    init(
        name: String,
        type: Int = 2,
        application_id: String? = nil,
        details: String? = nil,
        state: String? = nil,
        timestamps: Timestamps? = nil,
        assets: Assets? = nil
    ) {
        self.name = name
        self.type = type
        self.application_id = application_id
        self.details = details
        self.state = state
        self.timestamps = timestamps
        self.assets = assets
    }
}
