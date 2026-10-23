import SwiftUI

/// Everything the server knows about one file: format, quality, play history, tags, ReplayGain.
struct SongInfoView: View {
    let songId: String
    let fallback: Song

    @Environment(LibraryRepository.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var song: Song?

    var body: some View {
        let song = song ?? fallback
        NavigationStack {
            List {
                header(song)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                Section("Audio") {
                    row("Format", song.suffix?.uppercased() ?? song.contentType)
                    row("Bit Rate", AudioFormatText.bitRate(song.bitRate))
                    row("Sample Rate", AudioFormatText.sampleRate(song.samplingRate))
                    row("Bit Depth", song.bitDepth.flatMap { $0 > 0 ? "\($0)-bit" : nil })
                    row("Channels", song.channelCount.map { $0 == 1 ? "Mono" : $0 == 2 ? "Stereo" : "\($0)" })
                    row("Duration", song.duration.map { KMFormat.duration(TimeInterval($0)) })
                    row("Size", AudioFormatText.size(song.size))
                    row("On This Device", downloads.isDownloaded(song.id) ? "Downloaded" : nil)
                }

                Section("Listening") {
                    row("Plays", "\(song.playCount ?? 0)")
                    row("Last Played", song.played?.formatted(date: .abbreviated, time: .shortened))
                    row("Added", song.created?.formatted(date: .abbreviated, time: .omitted))
                    row("Rating", (song.userRating ?? 0) > 0 ? String(repeating: "★", count: song.userRating ?? 0) : nil)
                    row("Favorite", song.starred.map { "Since " + $0.formatted(date: .abbreviated, time: .omitted) })
                }

                Section("Tags") {
                    row("Album", song.album)
                    row("Track", trackText(song))
                    row("Year", song.year.map(String.init))
                    row("Genre", song.genre)
                    row("Composer", song.displayComposer)
                    row("BPM", song.bpm.flatMap { $0 > 0 ? "\($0)" : nil })
                    row("Comment", song.comment)
                }

                if let gain = song.replayGain {
                    Section("ReplayGain") {
                        row("Track Gain", AudioFormatText.gain(gain.trackGain))
                        row("Track Peak", gain.trackPeak.map { String(format: "%.4f", $0) })
                        row("Album Gain", AudioFormatText.gain(gain.albumGain))
                        row("Album Peak", gain.albumPeak.map { String(format: "%.4f", $0) })
                    }
                }

                if let path = song.path, !path.isEmpty {
                    Section("File") {
                        Text(path)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.secondaryLabel)
                            .textSelection(.enabled)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Song Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .task(id: songId) {
            self.song = await library.song(id: songId)
        }
    }

    private func header(_ song: Song) -> some View {
        VStack(spacing: 10) {
            ArtworkView(coverArt: song.coverArt, pointSize: 160, cornerRadius: 10)
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            Text(song.title)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            if let artist = song.artist {
                Text(artist)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            if let badge = AudioQualityBadge(song: song) {
                QualityBadge(badge: badge)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func trackText(_ song: Song) -> String? {
        guard let track = song.track else { return nil }
        if let disc = song.discNumber, disc > 1 { return "\(track) (Disc \(disc))" }
        return "\(track)"
    }
}

/// Presents the song info and playlist picker sheets requested through `UIState`. Attached once in the shell and once in
/// the full player, because a sheet can't appear over the player from the shell.
struct SongInfoPresenter: ViewModifier {
    var insidePlayer: Bool

    @Environment(UIState.self) private var ui

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { ui.isPlayerPresented == insidePlayer ? ui.songInfo : nil },
            set: { ui.songInfo = $0 }
        )) { song in
            SongInfoView(songId: song.id, fallback: song)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { ui.isPlayerPresented == insidePlayer ? ui.playlistPicker : nil },
            set: { ui.playlistPicker = $0 }
        )) { request in
            PlaylistPickerSheet(request: request)
                .presentationDetents([.medium, .large])
        }
    }
}
