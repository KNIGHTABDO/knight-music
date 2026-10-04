import Foundation
import SwiftUI
import GRDB

/// Main coordination service for Hermes AI chat and song arrival tracking.
@MainActor @Observable
final class HermesService {
    let settings = HermesSettings()
    let store = KnightConversationStore()
    private(set) var client: HermesClient

    weak var app: AppModel?
    weak var library: LibraryRepository?
    weak var artwork: AnimatedArtworkService?

    // Live streaming state
    var activeConversationId: String?
    var isRunning = false
    var currentStreamingText = ""
    var activeToolSteps: [ToolStep] = []

    // Import tracking state
    var importStatus: [String: String] = [:] // messageId -> status text
    var matchedSongs: [String: [Song]] = [:] // messageId -> [Song]

    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var arrivalTasks: [String: Task<Void, Never>] = [:]

    init() {
        self.client = HermesClient(settings: settings)
    }

    func configure(app: AppModel, library: LibraryRepository, artwork: AnimatedArtworkService) {
        self.app = app
        self.library = library
        self.artwork = artwork
    }

    func stopStreaming() {
        guard isRunning else { return }
        streamingTask?.cancel()
        streamingTask = nil

        if let conversationId = activeConversationId,
           var convo = store.conversation(for: conversationId) {
            var finalText = currentStreamingText
            if finalText.isEmpty {
                finalText = "Stopped."
            } else {
                finalText += "\n\n*(Stopped)*"
            }
            let assistantMsg = KnightMessage(
                role: .assistant,
                text: finalText,
                toolSteps: activeToolSteps.map { var s = $0; s.isRunning = false; return s },
                addedTracks: [],
                matchedSongIds: [],
                date: Date()
            )
            convo.messages.append(assistantMsg)
            convo.updatedAt = Date()
            store.save(convo)
        }

        isRunning = false
        activeConversationId = nil
        currentStreamingText = ""
        activeToolSteps = []
    }

    func sendMessage(
        conversationId: String,
        text: String,
        app: AppModel,
        library: LibraryRepository,
        artwork: AnimatedArtworkService,
        ui: UIState
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Find or create conversation
        var conversation = store.conversation(for: conversationId) ?? KnightConversation(
            id: conversationId,
            title: String(trimmed.prefix(40)),
            updatedAt: Date(),
            messages: []
        )

        // Append user message
        let userMessage = KnightMessage(role: .user, text: trimmed, date: Date())
        conversation.messages.append(userMessage)
        conversation.updatedAt = Date()
        store.save(conversation)

        // Reset live streaming state
        activeConversationId = conversationId
        isRunning = true
        currentStreamingText = ""
        activeToolSteps = []

        streamingTask?.cancel()
        streamingTask = Task {
            do {
                await self.client.update(baseURL: self.settings.baseURL, apiKey: self.settings.apiKey)
                let stream = await self.client.stream(conversation: conversationId, input: trimmed)

                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        self.currentStreamingText += delta
                    case .toolStarted(let id, let name, let argumentsJSON):
                        let info = ToolStepLabel.label(for: name, argumentsJSON: argumentsJSON)
                        let step = ToolStep(id: id, name: name, argumentsJSON: argumentsJSON, label: info.label, systemImage: info.systemImage, isRunning: true)
                        self.activeToolSteps.append(step)
                    case .toolFinished(let id):
                        if let index = self.activeToolSteps.firstIndex(where: { $0.id == id }) {
                            self.activeToolSteps[index].isRunning = false
                        }
                    case .completed:
                        break
                    case .failed(let error):
                        if self.currentStreamingText.isEmpty {
                            self.currentStreamingText = "Error: \(error)"
                        } else {
                            self.currentStreamingText += "\n\n*(Error: \(error))*"
                        }
                    }
                }

                // Stream finished successfully
                let parsed = KnightAddedParser.parse(self.currentStreamingText)
                let finalSteps = self.activeToolSteps.map { var s = $0; s.isRunning = false; return s }

                var assistantMessage = KnightMessage(
                    role: .assistant,
                    text: parsed.cleanedText,
                    toolSteps: finalSteps,
                    addedTracks: parsed.addedTracks,
                    matchedSongIds: [],
                    date: Date()
                )

                if var updatedConvo = self.store.conversation(for: conversationId) {
                    updatedConvo.messages.append(assistantMessage)
                    updatedConvo.updatedAt = Date()
                    self.store.save(updatedConvo)
                }

                self.isRunning = false
                self.activeConversationId = nil
                self.currentStreamingText = ""
                self.activeToolSteps = []

                // If tracks were added, run ArrivalWatcher
                if !parsed.addedTracks.isEmpty {
                    self.runArrivalWatcher(
                        conversationId: conversationId,
                        messageId: assistantMessage.id,
                        tracks: parsed.addedTracks,
                        app: app,
                        library: library,
                        artwork: artwork,
                        ui: ui
                    )
                }
            } catch is CancellationError {
                // Cancelled
            } catch {
                if var updatedConvo = self.store.conversation(for: conversationId) {
                    let errMsg = KnightMessage(
                        role: .assistant,
                        text: "Error: \(error.localizedDescription)",
                        toolSteps: self.activeToolSteps.map { var s = $0; s.isRunning = false; return s },
                        addedTracks: [],
                        matchedSongIds: [],
                        date: Date()
                    )
                    updatedConvo.messages.append(errMsg)
                    updatedConvo.updatedAt = Date()
                    self.store.save(updatedConvo)
                }
                self.isRunning = false
                self.activeConversationId = nil
                self.currentStreamingText = ""
                self.activeToolSteps = []
            }
        }
    }

    func runArrivalWatcher(
        conversationId: String,
        messageId: String,
        tracks: [AddedTrack],
        app: AppModel,
        library: LibraryRepository,
        artwork: AnimatedArtworkService,
        ui: UIState
    ) {
        importStatus[messageId] = "Importing to library…"
        ArrivalWatcher.shared.watch(
            conversationId: conversationId,
            messageId: messageId,
            tracks: tracks,
            app: app,
            library: library,
            artwork: artwork,
            ui: ui,
            hermes: self
        )
    }

    func appendMatchedSong(conversationId: String, messageId: String, song: Song) {
        if var list = matchedSongs[messageId] {
            if !list.contains(where: { $0.id == song.id }) {
                list.append(song)
                matchedSongs[messageId] = list
            }
        } else {
            matchedSongs[messageId] = [song]
        }

        if var convo = store.conversation(for: conversationId),
           let msgIndex = convo.messages.firstIndex(where: { $0.id == messageId }) {
            if !convo.messages[msgIndex].matchedSongIds.contains(song.id) {
                convo.messages[msgIndex].matchedSongIds.append(song.id)
                convo.updatedAt = Date()
                store.save(convo)
            }
        }
    }

    func loadSongsIfNeeded(for message: KnightMessage, library: LibraryRepository) async {
        guard matchedSongs[message.id] == nil, !message.matchedSongIds.isEmpty else { return }
        let songs = await library.songs(ids: message.matchedSongIds)
        if !songs.isEmpty {
            matchedSongs[message.id] = songs
        }
    }
}
