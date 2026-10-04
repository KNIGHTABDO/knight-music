import Foundation

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ToolStep: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var argumentsJSON: String
    var label: String
    var systemImage: String
    var isRunning: Bool
}

struct KnightMessage: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var role: MessageRole
    var text: String
    var toolSteps: [ToolStep] = []
    var addedTracks: [AddedTrack] = []
    var matchedSongIds: [String] = []
    var date: Date = Date()
    var runId: String? = nil
    var status: String? = nil
}

struct KnightConversation: Codable, Hashable, Identifiable, Sendable {
    var id: String // "km-<uuid>"
    var title: String
    var updatedAt: Date
    var messages: [KnightMessage]
}

/// Stores and loads Knight conversations to/from Application Support/Knight/ as JSON.
@MainActor @Observable
final class KnightConversationStore {
    var conversations: [KnightConversation] = []

    private var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Knight", isDirectory: true)
    }

    init() {
        loadAll()
    }

    func loadAll() {
        let url = directoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return
        }
        var loaded: [KnightConversation] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let convo = try? decoder.decode(KnightConversation.self, from: data) else {
                continue
            }
            loaded.append(convo)
        }
        loaded.sort(by: { $0.updatedAt > $1.updatedAt })
        self.conversations = loaded
    }

    func conversation(for id: String) -> KnightConversation? {
        conversations.first(where: { $0.id == id })
    }

    func save(_ conversation: KnightConversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort(by: { $0.updatedAt > $1.updatedAt })
        persist(conversation)
    }

    func delete(id: String) {
        conversations.removeAll(where: { $0.id == id })
        let file = directoryURL.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: file)
    }

    private func persist(_ conversation: KnightConversation) {
        let url = directoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent("\(conversation.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(conversation) {
            try? data.write(to: file, options: [.atomic])
        }
    }
}
