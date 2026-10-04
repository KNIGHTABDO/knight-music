import Foundation
import SwiftUI
import UIKit
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
    weak var ui: UIState?

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
    @ObservationIgnored private var currentRunId: String?
    @ObservationIgnored private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

    init() {
        self.client = HermesClient(settings: settings)

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidEnterBackground()
            }
        })

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillEnterForeground()
            }
        })

        Task {
            await self.recoverRunningMessages()
        }
    }

    func configure(app: AppModel, library: LibraryRepository, artwork: AnimatedArtworkService) {
        self.app = app
        self.library = library
        self.artwork = artwork
        Task {
            await self.recoverRunningMessages()
        }
    }

    // MARK: - Background Task Management

    private func beginBackgroundTask() {
        endBackgroundTask()
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "HermesRun") { [weak self] in
            let toEnd = bgTaskId
            bgTaskId = .invalid
            if toEnd != .invalid {
                UIApplication.shared.endBackgroundTask(toEnd)
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.backgroundTaskId == toEnd {
                    self.backgroundTaskId = .invalid
                }
                self.streamingTask?.cancel()
            }
        }
        self.backgroundTaskId = bgTaskId
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        let taskId = backgroundTaskId
        backgroundTaskId = .invalid
        UIApplication.shared.endBackgroundTask(taskId)
    }

    // MARK: - Lifecycle Notifications

    private func handleDidEnterBackground() {
        isBackgrounded = true
    }

    private func handleWillEnterForeground() {
        isBackgrounded = false
        Task {
            await self.recoverRunningMessages()
        }
    }

    // MARK: - Stop Actions

    func stopStreaming() {
        guard isRunning else { return }
        let runIdToStop = currentRunId
        streamingTask?.cancel()
        streamingTask = nil
        endBackgroundTask()

        if let conversationId = activeConversationId,
           var convo = store.conversation(for: conversationId) {
            var finalText = currentStreamingText
            if finalText.isEmpty {
                finalText = "Stopped."
            } else {
                finalText += "\n\n*(Stopped)*"
            }
            let finalSteps = activeToolSteps.map { var s = $0; s.isRunning = false; return s }

            if let runId = runIdToStop,
               let msgIdx = convo.messages.firstIndex(where: { $0.runId == runId }) {
                convo.messages[msgIdx].text = finalText
                convo.messages[msgIdx].toolSteps = finalSteps
                convo.messages[msgIdx].status = "stopped"
                convo.updatedAt = Date()
                store.save(convo)
            } else {
                let assistantMsg = KnightMessage(
                    role: .assistant,
                    text: finalText,
                    toolSteps: finalSteps,
                    addedTracks: [],
                    matchedSongIds: [],
                    date: Date(),
                    runId: runIdToStop,
                    status: "stopped"
                )
                convo.messages.append(assistantMsg)
                convo.updatedAt = Date()
                store.save(convo)
            }
        }

        if let runId = runIdToStop {
            Task { [client] in
                try? await client.stopRun(runId: runId)
            }
        }

        isRunning = false
        activeConversationId = nil
        currentStreamingText = ""
        activeToolSteps = []
        currentRunId = nil
    }

    func stop() {
        stopStreaming()
    }

    // MARK: - Sending Messages

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

        self.app = app
        self.library = library
        self.artwork = artwork
        self.ui = ui

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
                self.beginBackgroundTask()
                defer { self.endBackgroundTask() }

                await self.client.update(baseURL: self.settings.baseURL, apiKey: self.settings.apiKey)
                let runResponse = try await self.client.startRun(conversationId: conversationId, input: trimmed)
                let runId = runResponse.runId
                self.currentRunId = runId

                // Persist assistant message immediately with runId and "running" status
                let assistantMessageId = UUID().uuidString
                let assistantMsg = KnightMessage(
                    id: assistantMessageId,
                    role: .assistant,
                    text: "",
                    toolSteps: [],
                    addedTracks: [],
                    matchedSongIds: [],
                    date: Date(),
                    runId: runId,
                    status: "running"
                )

                if var updatedConvo = self.store.conversation(for: conversationId) {
                    updatedConvo.messages.append(assistantMsg)
                    updatedConvo.updatedAt = Date()
                    self.store.save(updatedConvo)
                }

                // Consume events from SSE
                await self.consumeEvents(
                    runId: runId,
                    conversationId: conversationId,
                    messageId: assistantMessageId,
                    app: app,
                    library: library,
                    artwork: artwork,
                    ui: ui
                )
            } catch is CancellationError {
                // Cancelled
            } catch {
                if self.isBackgrounded {
                    Log.api.info("Hermes startRun failed while in background: \(error.localizedDescription)")
                } else {
                    if var updatedConvo = self.store.conversation(for: conversationId) {
                        let errMsg = KnightMessage(
                            role: .assistant,
                            text: "Error: \(error.localizedDescription)",
                            toolSteps: self.activeToolSteps.map { var s = $0; s.isRunning = false; return s },
                            addedTracks: [],
                            matchedSongIds: [],
                            date: Date(),
                            status: "failed"
                        )
                        updatedConvo.messages.append(errMsg)
                        updatedConvo.updatedAt = Date()
                        self.store.save(updatedConvo)
                    }
                }
                if self.activeConversationId == conversationId {
                    self.isRunning = false
                    self.activeConversationId = nil
                    self.currentStreamingText = ""
                    self.activeToolSteps = []
                    self.currentRunId = nil
                }
            }
        }
    }

    // MARK: - Event Streaming

    private func consumeEvents(
        runId: String,
        conversationId: String,
        messageId: String,
        app: AppModel?,
        library: LibraryRepository?,
        artwork: AnimatedArtworkService?,
        ui: UIState?
    ) async {
        self.activeConversationId = conversationId
        self.isRunning = true
        self.currentStreamingText = ""
        self.activeToolSteps = []
        self.currentRunId = runId

        do {
            let stream = await self.client.events(runId: runId)
            var finalFullText: String? = nil

            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    self.currentStreamingText += delta
                case .toolStarted(let id, let name, let argumentsJSON):
                    let info = ToolStepLabel.label(for: name, argumentsJSON: argumentsJSON)
                    let step = ToolStep(
                        id: id,
                        name: name,
                        argumentsJSON: argumentsJSON,
                        label: info.label,
                        systemImage: info.systemImage,
                        isRunning: true
                    )
                    if let idx = self.activeToolSteps.firstIndex(where: { $0.id == id }) {
                        self.activeToolSteps[idx] = step
                    } else {
                        self.activeToolSteps.append(step)
                    }
                case .toolFinished(let id):
                    if let index = self.activeToolSteps.firstIndex(where: { $0.id == id }) {
                        self.activeToolSteps[index].isRunning = false
                    }
                case .completed(let fullText):
                    finalFullText = fullText
                case .failed(let error):
                    if self.currentStreamingText.isEmpty {
                        self.currentStreamingText = "Error: \(error)"
                    } else {
                        self.currentStreamingText += "\n\n*(Error: \(error))*"
                    }
                }
            }

            // Stream completed
            let rawText = finalFullText ?? self.currentStreamingText
            await self.handleRunCompleted(
                conversationId: conversationId,
                messageId: messageId,
                rawText: rawText,
                steps: self.activeToolSteps,
                app: app,
                library: library,
                artwork: artwork,
                ui: ui
            )
        } catch is CancellationError {
            // Cancelled
        } catch {
            if self.isBackgrounded {
                Log.api.info("Hermes stream died quietly in background: \(error.localizedDescription)")
            } else {
                if var updatedConvo = self.store.conversation(for: conversationId),
                   let msgIdx = updatedConvo.messages.firstIndex(where: { $0.id == messageId }) {
                    updatedConvo.messages[msgIdx].text = "Error: \(error.localizedDescription)"
                    updatedConvo.messages[msgIdx].status = "failed"
                    updatedConvo.messages[msgIdx].toolSteps = self.activeToolSteps.map { var s = $0; s.isRunning = false; return s }
                    updatedConvo.updatedAt = Date()
                    self.store.save(updatedConvo)
                }
            }
        }

        if self.activeConversationId == conversationId {
            self.isRunning = false
            self.activeConversationId = nil
            self.currentStreamingText = ""
            self.activeToolSteps = []
            self.currentRunId = nil
        }
    }

    private func handleRunCompleted(
        conversationId: String,
        messageId: String,
        rawText: String,
        steps: [ToolStep],
        app: AppModel?,
        library: LibraryRepository?,
        artwork: AnimatedArtworkService?,
        ui: UIState?
    ) async {
        let parsed = KnightAddedParser.parse(rawText)
        let finalSteps = steps.map { var s = $0; s.isRunning = false; return s }

        if var updatedConvo = self.store.conversation(for: conversationId),
           let msgIdx = updatedConvo.messages.firstIndex(where: { $0.id == messageId }) {
            updatedConvo.messages[msgIdx].text = parsed.cleanedText
            updatedConvo.messages[msgIdx].toolSteps = finalSteps
            updatedConvo.messages[msgIdx].addedTracks = parsed.addedTracks
            updatedConvo.messages[msgIdx].status = "completed"
            updatedConvo.updatedAt = Date()
            self.store.save(updatedConvo)
        }

        if self.activeConversationId == conversationId {
            self.isRunning = false
            self.activeConversationId = nil
            self.currentStreamingText = ""
            self.activeToolSteps = []
            self.currentRunId = nil
        }

        if !parsed.addedTracks.isEmpty,
           let app = app ?? self.app,
           let library = library ?? self.library,
           let artwork = artwork ?? self.artwork {
            let uiState = ui ?? self.ui ?? UIState()
            self.runArrivalWatcher(
                conversationId: conversationId,
                messageId: messageId,
                tracks: parsed.addedTracks,
                app: app,
                library: library,
                artwork: artwork,
                ui: uiState
            )
        }
    }

    // MARK: - Recovery of Running Messages

    func recoverRunningMessages() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        await client.update(baseURL: settings.baseURL, apiKey: settings.apiKey)

        struct RunningTarget {
            let conversationId: String
            let messageId: String
            let runId: String
            let existingSteps: [ToolStep]
            let existingText: String
        }

        var targets: [RunningTarget] = []
        for convo in store.conversations {
            for msg in convo.messages where msg.status == "running" {
                if let runId = msg.runId, !runId.isEmpty {
                    targets.append(RunningTarget(
                        conversationId: convo.id,
                        messageId: msg.id,
                        runId: runId,
                        existingSteps: msg.toolSteps,
                        existingText: msg.text
                    ))
                }
            }
        }

        guard !targets.isEmpty else { return }

        for target in targets {
            // If already actively streaming this exact run in foreground, don't interrupt it
            if self.isRunning && self.currentRunId == target.runId && self.streamingTask != nil {
                continue
            }

            do {
                let status = try await client.runStatus(runId: target.runId)
                if status.isCompleted {
                    let finalText = status.output ?? target.existingText
                    await handleRunCompleted(
                        conversationId: target.conversationId,
                        messageId: target.messageId,
                        rawText: finalText,
                        steps: target.existingSteps,
                        app: self.app,
                        library: self.library,
                        artwork: self.artwork,
                        ui: self.ui
                    )
                } else if status.status == "failed" {
                    if var updatedConvo = store.conversation(for: target.conversationId),
                       let msgIdx = updatedConvo.messages.firstIndex(where: { $0.id == target.messageId }) {
                        updatedConvo.messages[msgIdx].status = "failed"
                        updatedConvo.messages[msgIdx].text = status.output ?? (target.existingText.isEmpty ? "Run failed" : target.existingText)
                        updatedConvo.messages[msgIdx].toolSteps = target.existingSteps.map { var s = $0; s.isRunning = false; return s }
                        store.save(updatedConvo)
                    }
                } else {
                    // Still running: reconnect to /events (replaying from start)
                    beginBackgroundTask()
                    streamingTask?.cancel()
                    streamingTask = Task {
                        defer { self.endBackgroundTask() }
                        await self.consumeEvents(
                            runId: target.runId,
                            conversationId: target.conversationId,
                            messageId: target.messageId,
                            app: self.app,
                            library: self.library,
                            artwork: self.artwork,
                            ui: self.ui
                        )
                    }
                    // Connect to one active run in UI
                    break
                }
            } catch {
                Log.api.warning("Hermes: Failed to check run status for \(target.runId): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Arrival Watcher & Matched Songs (Untouched)

    private func runArrivalWatcher(
        conversationId: String,
        messageId: String,
        tracks: [AddedTrack],
        app: AppModel,
        library: LibraryRepository,
        artwork: AnimatedArtworkService,
        ui: UIState
    ) {
        importStatus[messageId] = "Importing to library…"

        arrivalTasks[messageId]?.cancel()
        arrivalTasks[messageId] = Task {
            var remainingTracks = tracks
            var foundSongs: [Song] = []

            // Check every 5s for up to 90s (18 cycles)
            for _ in 0..<18 {
                if Task.isCancelled { return }

                await app.refresh(force: false)

                if let database = library.database {
                    for track in remainingTracks {
                        let songs = (try? await database.pool.read { db in
                            try LibraryQueries.search(db, text: track.title).songs
                        }) ?? []

                        if let match = songs.first(where: { song in
                            guard let artist = song.artist else { return false }
                            return artist.localizedCaseInsensitiveCompare(track.artist) == .orderedSame
                                || artist.localizedStandardContains(track.artist)
                                || track.artist.localizedStandardContains(artist)
                        }) {
                            foundSongs.append(match)
                            remainingTracks.removeAll(where: { $0.id == track.id })

                            // Update message in conversation
                            self.appendMatchedSong(conversationId: conversationId, messageId: messageId, song: match)

                            // Show toast
                            ui.showToast("Added \(match.title) to your library")

                            // Prefetch animated artwork
                            artwork.prefetch(for: [match])
                        }
                    }
                }

                if remainingTracks.isEmpty {
                    // All tracks found!
                    self.importStatus[messageId] = nil
                    return
                }

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            // If not found after 90s
            if !remainingTracks.isEmpty {
                self.importStatus[messageId] = "Still importing — pull to refresh later"
            }
        }
    }

    private func appendMatchedSong(conversationId: String, messageId: String, song: Song) {
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
