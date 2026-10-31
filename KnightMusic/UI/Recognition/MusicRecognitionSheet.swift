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
    @State private var youTube = YouTubeState.idle
    @State private var youTubeSearch: Task<Void, Never>?

    private enum YouTubeState: Equatable {
        case idle
        case searching
        case choices([YTSong])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                // Scrolls only when the content is taller than the sheet; otherwise stays vertically centered.
                ScrollView {
                    Group {
                        switch app.shazam.state {
                        case .idle, .listening:
                            listeningView
                        case .matched(let track):
                            matchedView(track: track)
                        case .notFound:
                            notFoundView
                        case .error(let message):
                            errorView(message: message)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Music Recognition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.hero)
        .onAppear {
            isPulsing = true
            if ui.recognitionShouldStart || app.shazam.state == .idle {
                ui.recognitionShouldStart = false
                app.shazam.startListening()
            }
        }
        .onDisappear {
            youTubeSearch?.cancel()
            app.shazam.stopListening()
        }
        // .task, not onChange: the sheet can open on a match found while the app was in the background.
        .task(id: app.shazam.currentTrack?.id) {
            localMatch = nil
            youTubeSearch?.cancel()
            youTube = .idle
            guard let track = app.shazam.currentTrack else { return }
            isResolvingLocal = true
            localMatch = await app.shazam.resolveLocalMatch(title: track.title, artist: track.artist)
            isResolvingLocal = false
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

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
            }
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)

            VStack(spacing: 8) {
                Text("Listening for Music…")
                    .font(.kmSectionTitle)
                    .foregroundStyle(Theme.label)

                Text("Hold your device near the speaker. Other apps keep playing.")
                    .font(.kmRowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            DeviceAudioBroadcastButton()
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
                        startPlaying(local)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        dismiss()
                        ui.playlistPicker = PlaylistPickerRequest(songs: [local])
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Add to Playlist")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                    }
                    .buttonStyle(.glass)
                } else {
                    youTubeSection(track: track)
                }

                // Recognize another
                Button {
                    localMatch = nil
                    app.shazam.startListening()
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

    // MARK: - YouTube Music

    @ViewBuilder
    private func youTubeSection(track: RecognizedTrack) -> some View {
        if case .choices(let songs) = youTube {
            Text("Which one is it?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryLabel)
            ForEach(songs) { song in
                Button {
                    startPlaying(song.song)
                } label: {
                    choiceRow(song)
                }
                .buttonStyle(.plain)
            }
        } else {
            let isSearching = youTube == .searching
            Button {
                playOnYouTube(track)
            } label: {
                HStack(spacing: 8) {
                    if isSearching {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Play on YouTube Music")
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .buttonStyle(.glassProminent)
            .disabled(isSearching)

            if case .failed(let message) = youTube {
                Text(message)
                    .font(.kmRowSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choiceRow(_ song: YTSong) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.thumbnail.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Theme.secondaryBackground
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(song.artistLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func playOnYouTube(_ track: RecognizedTrack) {
        youTube = .searching
        youTubeSearch = Task {
            do {
                let result = try await YouTubeTrackMatcher.lookup(title: track.title, artist: track.artist)
                guard !Task.isCancelled else { return }
                switch result {
                case .match(let song):
                    startPlaying(song)
                case .choices(let songs):
                    youTube = songs.isEmpty ? .failed("This song isn't on YouTube Music.") : .choices(songs)
                }
            } catch {
                guard !Task.isCancelled else { return }
                Log.app.error("YouTube lookup for recognized song failed: \(error.localizedDescription)")
                youTube = .failed("Couldn't reach YouTube Music. Tap to try again.")
            }
        }
    }

    private func startPlaying(_ song: Song) {
        Haptics.impact(.medium)
        player.play([song], startAt: 0, shuffle: false)
        ui.playerAfterRecognition = true
        dismiss()
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

            DeviceAudioBroadcastButton()

            Button {
                Haptics.impact(.light)
                app.shazam.startListening()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .buttonStyle(.glassProminent)
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
                Text("Couldn’t Identify")
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
                app.shazam.startListening()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .buttonStyle(.glassProminent)
        }
    }
}
