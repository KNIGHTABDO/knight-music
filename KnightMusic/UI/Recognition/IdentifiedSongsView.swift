import SwiftUI

struct IdentifiedSongsView: View {
    @Environment(UIState.self) private var ui

    @State private var store = RecognizedTracksStore.shared
    @State private var showClearConfirmation = false

    var body: some View {
        Group {
            if store.tracks.isEmpty {
                EmptyStateView(
                    title: "No Identified Songs",
                    systemImage: "waveform.circle.fill",
                    message: "Songs you identify with Knight Music or Control Center will appear here.",
                    actionTitle: "Identify Song",
                    action: {
                        ui.startRecognition()
                    }
                )
            } else {
                List {
                    ForEach(store.tracks) { track in
                        Button {
                            ui.openRecognition(track, action: .play)
                        } label: {
                            HStack(spacing: 12) {
                                if let url = track.artworkURL {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        default:
                                            ZStack {
                                                Theme.secondaryBackground
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 16))
                                                    .foregroundStyle(Theme.tertiaryLabel)
                                            }
                                        }
                                    }
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                                } else {
                                    ZStack {
                                        Theme.secondaryBackground
                                        Image(systemName: "music.note")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Theme.tertiaryLabel)
                                    }
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title)
                                        .font(.kmRowTitle)
                                        .foregroundStyle(Theme.label)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text(track.artist)
                                            .font(.kmRowSubtitle)
                                            .foregroundStyle(Theme.secondaryLabel)
                                            .lineLimit(1)

                                        Text("•")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.tertiaryLabel)

                                        Text(track.recognizedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(Theme.tertiaryLabel)
                                    }
                                }

                                Spacer()

                                Color.clear.frame(width: 44, height: 44)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .trailing) {
                            Menu {
                                historyActions(track)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Actions for \(track.title)")
                        }
                        .contextMenu { historyActions(track) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.remove(id: track.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Identified Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if !store.tracks.isEmpty {
                        Button {
                            showClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                        }
                        .accessibilityLabel("Clear History")
                    }

                    Button {
                        Haptics.impact(.light)
                        ui.startRecognition()
                    } label: {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Identify Song")
                }
            }
        }
        .confirmationDialog("Clear Identified Songs", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                store.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete all identified songs from history?")
        }
    }

    @ViewBuilder
    private func historyActions(_ track: RecognizedTrack) -> some View {
        Button {
            ui.openRecognition(track, action: .play)
        } label: {
            Label("Play Song", systemImage: "play.fill")
        }

        Button {
            ui.openRecognition(track, action: .playNext)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            ui.openRecognition(track, action: .addToQueue)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Button {
            ui.openRecognition(track, action: .addToLibrary)
        } label: {
            Label("Add to Library", systemImage: "plus.circle")
        }

        if let shareURL = track.appleMusicURL {
            ShareLink(item: shareURL) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        } else {
            ShareLink(item: "\(track.title) — \(track.artist)") {
                Label("Share Song", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        Button(role: .destructive) {
            store.remove(id: track.id)
        } label: {
            Label("Remove from History", systemImage: "trash")
        }
    }

}
