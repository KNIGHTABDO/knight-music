import SwiftUI

struct IdentifiedSongsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui

    @State private var store = RecognizedTracksStore.shared
    @State private var showClearConfirmation = false

    var body: some View {
        Group {
            if store.tracks.isEmpty {
                EmptyStateView(
                    title: "No Identified Songs",
                    systemImage: "shazam.logo.fill",
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
                            handleTap(track: track)
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

                                Image(systemName: "ellipsis")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.tertiaryLabel)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                handleTap(track: track)
                            } label: {
                                Label("Play Song", systemImage: "play.fill")
                            }

                            Button {
                                ui.askKnight("Download song \(track.title) by \(track.artist) to my library")
                            } label: {
                                Label("Download to Library", systemImage: "arrow.down.circle")
                            }

                            if let shareURL = track.appleMusicURL {
                                ShareLink(item: shareURL) {
                                    Label("Share Link", systemImage: "square.and.arrow.up")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                store.remove(id: track.id)
                            } label: {
                                Label("Remove from History", systemImage: "trash")
                            }
                        }
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
                        Image(systemName: "shazam.logo.fill")
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

    private func handleTap(track: RecognizedTrack) {
        Task {
            if let song = await app.shazam.resolveLocalMatch(title: track.title, artist: track.artist, library: library) {
                await MainActor.run {
                    Haptics.impact(.medium)
                    player.play([song], startAt: 0, shuffle: false)
                }
            } else {
                await MainActor.run {
                    Haptics.impact(.light)
                    ui.askKnight("Play \(track.title) by \(track.artist) from YouTube Music")
                }
            }
        }
    }
}
