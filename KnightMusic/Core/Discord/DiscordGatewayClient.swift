import Foundation
import UIKit

/// Manages real-time WebSocket connection to the Discord Gateway v10.
/// Sends Opcode 3 (Presence Update) for instantaneous profile updates.
@MainActor
final class DiscordGatewayClient {
    private static let defaultGatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!

    var onStateChange: ((DiscordConnectionState) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var token: String = ""
    private var sessionId: String?
    private var resumeGatewayURL: String?
    private var lastSequence: Int?
    private var currentActivities: [DiscordActivity] = []
    private var currentUsername: String?
    private var isIntentionalDisconnect = false
    private var retryCount = 0

    private(set) var currentState: DiscordConnectionState = .disconnected {
        didSet {
            if oldValue != currentState {
                onStateChange?(currentState)
            }
        }
    }

    var isConnected: Bool {
        if case .connected = currentState { return true }
        return false
    }

    init() {}

    // MARK: - Connection Lifecycle

    func connect(token: String) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            disconnect()
            return
        }

        if self.token != cleanToken {
            self.token = cleanToken
            self.sessionId = nil
            self.resumeGatewayURL = nil
            self.lastSequence = nil
            self.currentUsername = nil
        }

        isIntentionalDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil

        guard webSocketTask == nil else { return }

        currentState = .connecting
        startWebSocket()
    }

    func disconnect() {
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        stopWebSocket()
        sessionId = nil
        resumeGatewayURL = nil
        lastSequence = nil
        currentState = .disconnected
    }

    // MARK: - Presence Updates

    func updatePresence(activities: [DiscordActivity]) {
        self.currentActivities = activities

        guard !token.isEmpty else { return }

        if isConnected {
            sendPresencePayload(activities: activities)
        } else if !isIntentionalDisconnect {
            connect(token: token)
        }
    }

    // MARK: - WebSocket Engine

    private func startWebSocket() {
        stopWebSocket()

        let url = resumeGatewayURL.flatMap(URL.init(string:)) ?? Self.defaultGatewayURL
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        listenForMessages()
    }

    private func stopWebSocket() {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        session?.invalidateAndCancel()
        session = nil
    }

    private func listenForMessages() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.listenForMessages()
                case .failure(let error):
                    self.handleWebSocketFailure(error: error)
                }
            }
        }
    }

    private func handleWebSocketFailure(error: Error) {
        guard !isIntentionalDisconnect else { return }

        let nsError = error as NSError
        // Discord Close Code 4004 = Authentication Failed
        if nsError.code == 4004 || nsError.localizedDescription.contains("4004") {
            currentState = .error("Authentication Failed: Invalid Discord token.")
            stopWebSocket()
            return
        }

        currentState = .connecting
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !isIntentionalDisconnect, reconnectTask == nil else { return }

        let delay = min(pow(2.0, Double(retryCount)), 30.0)
        retryCount += 1

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isIntentionalDisconnect else { return }
            self.reconnectTask = nil
            self.startWebSocket()
        }
    }

    // MARK: - Message Parsing

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let d = text.data(using: .utf8) else { return }
            data = d
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else {
            return
        }

        if let seq = json["s"] as? Int {
            lastSequence = seq
        }

        switch op {
        case 10: // HELLO
            if let d = json["d"] as? [String: Any],
               let interval = d["heartbeat_interval"] as? Double {
                startHeartbeat(intervalMs: interval)
                sendIdentifyOrResume()
            }

        case 11: // HEARTBEAT_ACK
            break

        case 1: // HEARTBEAT requested by server
            sendHeartbeat()

        case 7: // RECONNECT requested by server
            startWebSocket()

        case 9: // INVALID_SESSION
            let canResume = (json["d"] as? Bool) == true
            if !canResume {
                sessionId = nil
                resumeGatewayURL = nil
                lastSequence = nil
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.sendIdentifyOrResume()
            }

        case 0: // DISPATCH
            let event = json["t"] as? String
            handleDispatch(event: event, data: json["d"] as? [String: Any])

        default:
            break
        }
    }

    private func handleDispatch(event: String?, data: [String: Any]?) {
        guard let event else { return }

        switch event {
        case "READY":
            retryCount = 0
            if let data {
                sessionId = data["session_id"] as? String
                resumeGatewayURL = data["resume_gateway_url"] as? String

                if let user = data["user"] as? [String: Any] {
                    let globalName = user["global_name"] as? String
                    let username = user["username"] as? String ?? "User"
                    let display = (globalName?.isEmpty == false) ? globalName! : username
                    currentUsername = display
                    currentState = .connected(username: display)
                } else {
                    currentState = .connected(username: "Discord User")
                }
            }

            if !currentActivities.isEmpty {
                sendPresencePayload(activities: currentActivities)
            }

        case "RESUMED":
            retryCount = 0
            let name = currentUsername ?? "Discord User"
            currentState = .connected(username: name)
            if !currentActivities.isEmpty {
                sendPresencePayload(activities: currentActivities)
            }

        default:
            break
        }
    }

    // MARK: - Outgoing Payloads

    private func startHeartbeat(intervalMs: Double) {
        heartbeatTask?.cancel()
        let intervalSeconds = max(intervalMs / 1000.0, 5.0)

        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                guard let self, self.webSocketTask != nil else { break }
                self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        let payload: [String: Any] = [
            "op": 1,
            "d": lastSequence as Any
        ]
        sendJSON(payload)
    }

    private func sendIdentifyOrResume() {
        if let sessionId, let lastSequence {
            let resumePayload: [String: Any] = [
                "op": 6,
                "d": [
                    "token": token,
                    "session_id": sessionId,
                    "seq": lastSequence
                ]
            ]
            sendJSON(resumePayload)
        } else {
            let identifyPayload: [String: Any] = [
                "op": 2,
                "d": [
                    "token": token,
                    "capabilities": 16381,
                    "properties": [
                        "os": "iOS",
                        "browser": "Discord iOS",
                        "device": "iPhone"
                    ],
                    "presence": [
                        "status": "online",
                        "since": 0,
                        "activities": serializeActivities(currentActivities),
                        "afk": false
                    ]
                ]
            ]
            sendJSON(identifyPayload)
        }
    }

    private func sendPresencePayload(activities: [DiscordActivity]) {
        let payload: [String: Any] = [
            "op": 3,
            "d": [
                "since": NSNull(),
                "activities": serializeActivities(activities),
                "status": "online",
                "afk": false
            ]
        ]
        sendJSON(payload)
    }

    private func serializeActivities(_ activities: [DiscordActivity]) -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(activities),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        task.send(.string(text)) { error in
            if let error {
                Log.app.warning("DiscordGatewayClient: Send failed: \(error.localizedDescription)")
            }
        }
    }
}
