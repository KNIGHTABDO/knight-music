import SwiftUI

struct MusicRecognitionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui

    @State private var isPulsing = false
    @State private var localMatch: Song?
    @State private var isResolvingLocal = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer(minLength: 16)

                    switch app.shazam.state {
                    case .idle, .listening, .matching:
                        listeningView
                    case .matched(let track):
                        matchedView(track: track)
                    case .notFound:
                        notFoundView
                    case .error(let message):
                        errorView(message: message)
                    }

                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 24)
            }
            .navigationTitle("Music Recognition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.68), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.hero)
        .onAppear {
            isPulsing = true
            app.shazam.startListening(library: library)
        }
        .onDisappear {
            app.shazam.stopListening()
        }
        .onChange(of: app.shazam.currentTrack?.id) { _, _ in
            if let track = app.shazam.currentTrack {
                isResolvingLocal = true
                Task {
                    let song = await app.shazam.resolveLocalMatch(title: track.title, artist: track.artist, library: library)
                    await MainActor.run {
                        self.localMatch = song
                        self.isResolvingLocal = false
                    }
                }
            }
        }
    }

    // MARK: - Listening State

    private var listeningView: some View {
        VStack(spacing: 32) {
            ZStack {
                // Outermost pulsing glow
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 220, height: 220)
                    .scaleEffect(isPulsing ? 1.25 : 0.85)

                // Middle ring
                Circle()
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 2)
                    .frame(width: 170, height: 170)
                    .scaleEffect(isPulsing ? 1.15 : 0.9)

                // Inner core button
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 110, height: 110)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 16, x: 0, y: 8)

                Image(systemName: "shazam.logo.fill")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
            }
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)

            VStack(spacing: 8) {
                Text("Listening for Music…")
                    .font(.kmSectionTitle)
                    .foregroundStyle(Theme.label)

                Text("Keep your device near the audio to identify the song.")
                    .font(.kmRowSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(height: 44)
                    .padding(.horizontal, 32)
                    .background(Theme.secondaryBackground)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Matched State

    @ViewBuilder
    private func matchedView(track: RecognizedTrack) -> some View {
        VStack(spacing: 20) {
            // Artwork
            if let artworkURL = track.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        ZStack {
                            Theme.secondaryBackground
                            Image(systemName: "music.note")
                                .font(.system(size: 40))
                                .foregroundStyle(Theme.tertiaryLabel)
                        }
                    @unknown default:
                        Theme.secondaryBackground
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 6)
            } else {
                ZStack {
                    Theme.secondaryBackground
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.tertiaryLabel)
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }

            // Track info
            VStack(spacing: 6) {
                Text(track.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(track.artist)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)

                if let local = localMatch {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("In Your Library")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Theme.accent.opacity(0.12))
                    .clipShape(Capsule())
                    .padding(.top, 4)
                }
            }

            // Action Buttons
            VStack(spacing: 10) {
                if let local = localMatch {
                    Button {
                        Haptics.impact(.medium)
                        player.play([local], startAt: 0, shuffle: false)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Play in Knight Music")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        dismiss()
                        ui.playlistPicker = PlaylistPickerRequest(songs: [local])
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Add to Playlist")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Theme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        dismiss()
                        ui.askKnight("Play \(track.title) by \(track.artist) from YouTube Music")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                            Text("Stream on YouTube Music")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        dismiss()
                        ui.askKnight("Download song \(track.title) by \(track.artist) to my library")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("Ask Knight to Download")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Theme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                // Recognize another
                Button {
                    localMatch = nil
                    app.shazam.startListening(library: library)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Identify Another Song")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Not Found State

    private var notFoundView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Theme.secondaryBackground)
                    .frame(width: 100, height: 100)

                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            VStack(spacing: 8) {
                Text("No Match Found")
                    .font(.kmSectionTitle)
                    .foregroundStyle(Theme.label)

                Text("We couldn’t recognize this song. Try moving closer to the speaker or waiting for the music to become clearer.")
                    .font(.kmRowSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Button {
                Haptics.impact(.light)
                app.shazam.startListening(library: library)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Error State

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Theme.secondaryBackground)
                    .frame(width: 100, height: 100)

                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 42))
                    .foregroundStyle(.yellow)
            }

            VStack(spacing: 8) {
                Text("Recognition Error")
                    .font(.kmSectionTitle)
                    .foregroundStyle(Theme.label)

                Text(message)
                    .font(.kmRowSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Button {
                Haptics.impact(.light)
                app.shazam.startListening(library: library)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
