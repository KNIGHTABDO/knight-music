import SwiftUI

/// Root conversation list and empty state for Knight AI.
struct KnightView: View {
    @Binding var path: NavigationPath

    @Environment(HermesService.self) private var hermes
    @Environment(UIState.self) private var ui

    @State private var showingSettings = false

    private static let suggestions: [String] = [
        "Add the latest Travis Scott album",
        "Make me a chill rai playlist",
        "Add Blinding Lights by The Weeknd",
        "What did I add this week?"
    ]

    init(path: Binding<NavigationPath> = .constant(NavigationPath())) {
        self._path = path
    }

    var body: some View {
        Group {
            if !hermes.settings.isConfigured {
                unconfiguredView
            } else if hermes.store.conversations.isEmpty {
                emptySuggestionsView
            } else {
                conversationsList
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Knight")
        .toolbar {
            if hermes.settings.isConfigured {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                HermesSettingsView()
            }
        }
        .task {
            handleDraftIfNeeded()
        }
        .onChange(of: ui.knightDraft) { _, _ in
            handleDraftIfNeeded()
        }
    }

    // MARK: - Unconfigured

    private var unconfiguredView: some View {
        EmptyStateView(
            title: "Ask Knight",
            systemImage: "sparkles",
            message: "Ask for any song, album or playlist — Knight adds it to your library.",
            actionTitle: "Connect Hermes"
        ) {
            showingSettings = true
        }
    }


    // MARK: - Empty with Suggestions

    private var emptySuggestionsView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 40)

                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)

                VStack(spacing: 8) {
                    Text("Ask Knight")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.label)

                    Text("Ask for any song, album or playlist — Knight adds it to your library.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 10) {
                    ForEach(Self.suggestions, id: \.self) { chip in
                        Button {
                            startNewChat(withDraft: chip)
                        } label: {
                            HStack {
                                Image(systemName: "sparkle")
                                    .font(.caption)
                                Text(chip)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .foregroundStyle(Theme.label)
                            .background(Color(uiColor: .systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - Conversations List

    private var conversationsList: some View {
        List {
            ForEach(hermes.store.conversations) { conv in
                NavigationLink(value: Route.knightChat(id: conv.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(conv.title)
                                .font(.headline)
                                .foregroundStyle(Theme.label)
                                .lineLimit(1)

                            Spacer()

                            Text(conv.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryLabel)
                        }

                        if let lastMessage = conv.messages.last?.text, !lastMessage.isEmpty {
                            Text(lastMessage)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryLabel)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let conv = hermes.store.conversations[index]
                    hermes.store.delete(id: conv.id)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Actions

    private func handleDraftIfNeeded() {
        guard let draft = ui.knightDraft, !draft.isEmpty else { return }
        ui.knightDraft = nil
        startNewChat(withDraft: draft)
    }

    private func startNewChat(withDraft draft: String? = nil) {
        let newId = "km-\(UUID().uuidString.lowercased())"
        path.append(Route.knightChat(id: newId, draft: draft))
    }
}
