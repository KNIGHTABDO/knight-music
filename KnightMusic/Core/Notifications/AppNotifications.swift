import Observation
import UIKit
import UserNotifications

/// Local notifications for things that finish while the user is elsewhere: download batches, Knight replies,
/// "Add to Navidrome" imports and server arrivals. No push (the app is sideloaded), so everything is posted by the
/// running app; music playback keeps it alive in the background. Each kind can be switched off in
/// Settings → Notifications.
@MainActor @Observable
final class AppNotifications: NSObject {
    static let shared = AppNotifications()

    enum Kind: String, CaseIterable, Identifiable {
        case downloads, knight, imports, arrivals

        var id: String { rawValue }

        var title: String {
            switch self {
            case .downloads: "Downloads"
            case .knight: "Knight Replies"
            case .imports: "Add to Navidrome"
            case .arrivals: "New on Your Server"
            }
        }

        var detail: String {
            switch self {
            case .downloads: "When a batch finishes or songs fail to download."
            case .knight: "When Knight answers while you're in another app. Reply right from the notification."
            case .imports: "When a YouTube song finishes importing, or the import fails."
            case .arrivals: "When songs Knight added show up in your library, ready to play."
            }
        }

        var systemImage: String {
            switch self {
            case .downloads: "arrow.down.circle"
            case .knight: "bubble.left.and.text.bubble.right"
            case .imports: "square.and.arrow.down.on.square"
            case .arrivals: "sparkles"
            }
        }

        fileprivate var defaultsKey: String { "notify.\(rawValue)" }
    }

    enum Category {
        static let downloads = "km.downloads"
        static let downloadsFailed = "km.downloads.failed"
        static let knight = "km.knight"
        static let song = "km.song"
        static let failure = "km.failure"
    }

    enum Action {
        static let retry = "km.retry"
        static let reply = "km.reply"
        static let play = "km.play"
        static let open = "km.open"
    }

    /// userInfo keys.
    enum Key {
        static let kind = "kind"
        static let route = "route"
        static let conversationId = "conversationId"
        static let songId = "songId"
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var enabledKinds: Set<Kind>
    /// The Knight conversation on screen; its replies don't also arrive as banners.
    var visibleConversationId: String?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var didInstall = false
    @ObservationIgnored private var askedThisLaunch = false

    override private init() {
        let defaults = UserDefaults.standard
        enabledKinds = Set(Kind.allCases.filter { defaults.object(forKey: $0.defaultsKey) as? Bool ?? true })
        super.init()
    }

    /// Call once at launch, before the first scene connects, so a tap on a notification that launched the app
    /// reaches the delegate.
    func install() {
        guard !didInstall else { return }
        didInstall = true
        center.delegate = self
        let open = UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground])
        // Retry and Play finish in the app (they open Downloads / the player), so they bring it to the front
        // instead of queueing silently until the next time Duet is opened.
        let retry = UNNotificationAction(identifier: Action.retry, title: "Retry", options: [.foreground],
                                         icon: UNNotificationActionIcon(systemImageName: "arrow.clockwise"))
        let play = UNNotificationAction(identifier: Action.play, title: "Play", options: [.foreground],
                                        icon: UNNotificationActionIcon(systemImageName: "play.fill"))
        let reply = UNTextInputNotificationAction(identifier: Action.reply, title: "Reply", options: [],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message Knight")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.downloads, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.downloadsFailed, actions: [retry, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.knight, actions: [reply, open], intentIdentifiers: [],
                                   options: [.hiddenPreviewsShowTitle]),
            UNNotificationCategory(identifier: Category.song, actions: [play, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.failure, actions: [open], intentIdentifiers: []),
        ])
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func isEnabled(_ kind: Kind) -> Bool { enabledKinds.contains(kind) }

    func setEnabled(_ kind: Kind, _ enabled: Bool) {
        if enabled { enabledKinds.insert(kind) } else { enabledKinds.remove(kind) }
        UserDefaults.standard.set(enabled, forKey: kind.defaultsKey)
        if enabled { Task { await requestAuthorizationIfNeeded() } }
    }

    /// Asks the system once (the first time something notifiable starts); later calls only report the answer.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorization()
        if authorization == .notDetermined, !askedThisLaunch, !DebugLaunch.isDemo {
            askedThisLaunch = true
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                Log.app.error("Notification authorization failed: \(error.localizedDescription)")
            }
            await refreshAuthorization()
        }
        return canPost
    }

    var canPost: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// Posts now. A later notification with the same id replaces the earlier one (e.g. a growing download batch).
    func post(
        _ kind: Kind,
        id: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        category: String,
        info: [String: String] = [:],
        thread: String? = nil,
        imageData: Data? = nil,
        relevance: Double = 0.5
    ) {
        guard isEnabled(kind) else { return }
        Task {
            await refreshAuthorization()
            guard canPost else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            content.categoryIdentifier = category
            content.threadIdentifier = thread ?? kind.rawValue
            content.sound = .default
            content.relevanceScore = relevance
            content.targetContentIdentifier = info[Key.route]
            var userInfo: [String: String] = info
            userInfo[Key.kind] = kind.rawValue
            content.userInfo = userInfo
            if let imageData, let attachment = Self.attachment(imageData, id: id) {
                content.attachments = [attachment]
            }
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                Log.app.error("Notification \(id) failed: \(error.localizedDescription)")
            }
        }
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Clears a conversation's delivered replies once the user reads it in the app.
    func clearKnight(conversationId: String) {
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { ($0.request.content.userInfo[Key.conversationId] as? String) == conversationId }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    private static func attachment(_ data: Data, id: String) -> UNNotificationAttachment? {
        // The system moves the file into its own store, so each attachment needs its own temporary copy.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notification-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: id, url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"])
        } catch {
            Log.app.error("Notification artwork failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Presentation and responses

    fileprivate func presentation(kind: Kind?, conversationId: String?) -> UNNotificationPresentationOptions {
        switch kind {
        case .knight:
            // The open chat already shows the reply as it streams.
            return conversationId != nil && conversationId == visibleConversationId ? [] : [.banner, .list, .sound]
        case .downloads, .imports, .arrivals:
            // The transfers pill, import banner and toasts already show these in the app; keep a quiet record.
            return [.list]
        case .none:
            return [.banner, .list, .sound]
        }
    }

    fileprivate func handle(action: String, info: [String: String], text: String?) {
        let kind = info[Key.kind].flatMap(Kind.init(rawValue:))
        switch action {
        case Action.reply:
            guard let conversationId = info[Key.conversationId], let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            AppModel.shared?.hermes.sendReply(conversationId: conversationId, text: text)
        case Action.retry:
            AppActionRouter.shared.submit("retry-downloads")
        case Action.play:
            if let songId = info[Key.songId] { AppActionRouter.shared.submit("play-song:\(songId)") }
        default:
            if let route = info[Key.route] {
                AppActionRouter.shared.submit(route)
            } else if kind == .downloads {
                AppActionRouter.shared.submit("downloads")
            }
        }
    }
}

extension AppNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let kind = (info[Key.kind] as? String).flatMap(Kind.init(rawValue:))
        let conversationId = info[Key.conversationId] as? String
        return await MainActor.run { presentation(kind: kind, conversationId: conversationId) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run { handle(action: action, info: info, text: text) }
    }
}
