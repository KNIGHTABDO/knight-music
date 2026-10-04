import SwiftUI

/// Transcript and interactive chat interface for a Knight conversation.
struct KnightChatView: View {
    let conversationId: String
    var initialDraft: String? = nil

    @Environment(HermesService.self) private var hermes
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AnimatedArtworkService.self) private var artwork
    @Environment(UIState.self) private var ui

    @State private var inputText: String = ""
    @State private var dictation = SpeechDictationManager()

    private var conversation: KnightConversation? {
        hermes.store.conversation(for: conversationId)
    }

    private var isStreamingThisConversation: Bool {
        hermes.isRunning && hermes.activeConversationId == conversationId
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hermes.isRunning
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let messages = conversation?.messages {
                        ForEach(messages) { message in
                            messageView(message)
                        }
                    }

                    // Live active streaming message
                    if isStreamingThisConversation {
                        liveStreamingView
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottomID")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: hermes.currentStreamingText) { _, _ in
                withAnimation(.smooth) {
                    proxy.scrollTo("bottomID", anchor: .bottom)
                }
            }
            .onChange(of: hermes.activeToolSteps.count) { _, _ in
                withAnimation(.smooth) {
                    proxy.scrollTo("bottomID", anchor: .bottom)
                }
            }
            .onAppear {
                if let draft = initialDraft, !draft.isEmpty {
                    inputText = draft
                }
                proxy.scrollTo("bottomID", anchor: .bottom)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(conversation?.title ?? "Knight")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            composerBar
        }
        .onDisappear {
            dictation.stop()
        }
    }

    // MARK: - Message Rows

    @ViewBuilder
    private func messageView(_ message: KnightMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .id(message.id)

        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                markdownText(message.text)

                if !message.toolSteps.isEmpty {
                    toolStepsList(message.toolSteps)
                }

                if !message.addedTracks.isEmpty {
                    addedTracksSection(for: message)
                }
            }
            .id(message.id)
            .task {
                await hermes.loadSongsIfNeeded(for: message, library: library)
            }
        }
    }

    private var liveStreamingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hermes.currentStreamingText.isEmpty && hermes.activeToolSteps.isEmpty {
                // Typing shimmer before first token
                HStack(spacing: 5) {
                    Circle().frame(width: 8, height: 8)
                    Circle().frame(width: 8, height: 8)
                    Circle().frame(width: 8, height: 8)
                }
                .foregroundStyle(Theme.secondaryLabel)
                .shimmering()
                .padding(.vertical, 8)
            } else {
                if !hermes.currentStreamingText.isEmpty {
                    markdownText(hermes.currentStreamingText)
                }

                if !hermes.activeToolSteps.isEmpty {
                    toolStepsList(hermes.activeToolSteps)
                }
            }
        }
    }

    private func markdownText(_ text: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attr = try? AttributedString(markdown: text, options: options) {
            return Text(attr)
                .font(.system(size: 17))
                .foregroundStyle(Theme.label)
        } else {
            return Text(text)
                .font(.system(size: 17))
                .foregroundStyle(Theme.label)
        }
    }

    // MARK: - Tool Steps

    private func toolStepsList(_ steps: [ToolStep]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    if step.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.secondaryLabel)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.green)
                    }

                    Image(systemName: step.systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)

                    Text(step.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(uiColor: .systemGray6).opacity(0.5), in: Capsule())
                .animation(.smooth, value: step.isRunning)
            }
        }
    }

    // MARK: - Added Tracks

    private func addedTracksSection(for message: KnightMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = hermes.importStatus[message.id] {
                HStack(spacing: 6) {
                    if status.contains("Still") {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(uiColor: .systemGray6).opacity(0.5), in: Capsule())
            }

            let songs = hermes.matchedSongs[message.id] ?? []
            if !songs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(songs) { song in
                            trackCard(song: song)
                        }
                    }
                }
            } else if !message.addedTracks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(message.addedTracks) { track in
                            addedTrackPlaceholderCard(track: track)
                        }
                    }
                }
            }
        }
    }

    private func trackCard(song: Song) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: song.coverArt, pointSize: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text(song.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Button {
                        player.play([song], startAt: 0, shuffle: false)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Play")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        player.enqueue([song], next: true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 10))
                            Text("Play Next")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .systemGray6).opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func addedTrackPlaceholderCard(track: AddedTrack) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: nil, pointSize: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Importing…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .systemGray6).opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Composer Bar

    private var composerBar: some View {
        HStack(spacing: 8) {
            Button {
                dictation.toggle { recognized in
                    inputText = recognized
                }
            } label: {
                Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 18))
                    .foregroundStyle(dictation.isRecording ? Theme.accent : Theme.secondaryLabel)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            TextField("Ask Knight…", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .foregroundStyle(Theme.label)

            if isStreamingThisConversation {
                Button {
                    hermes.stopStreaming()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.accent : Theme.tertiaryLabel)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        dictation.stop()

        hermes.sendMessage(
            conversationId: conversationId,
            text: text,
            app: app,
            library: library,
            artwork: artwork,
            ui: ui
        )
    }
}
