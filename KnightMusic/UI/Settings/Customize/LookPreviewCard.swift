import SwiftUI

/// Live preview pinned above the Customize list. It is built from the real views and data (the playing
/// song, or the last one played, its cover and palette, and recent albums), so every change shows as it
/// will look in the app.
struct LookPreviewCard: View {
    @Environment(LookStore.self) private var looks
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryRepository.self) private var library

    var body: some View {
        let recentSongs = library.recentlyPlayedSongs(limit: 1)
        let albums = library.homeList(.recent)
        let artists = library.recentlyAddedArtists(limit: 1)
        let song = player.currentSong ?? recentSongs.value.first

        Group {
            if let song {
                content(song: song, albums: Array(albums.value.prefix(4)), artist: artists.value.first)
            } else {
                ContentUnavailableView("Play a song to preview your look", systemImage: "paintpalette")
                    .frame(height: 210)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .observing(recentSongs)
        .observing(albums)
        .observing(artists)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of \(looks.current.name)")
    }

    private func content(song: Song, albums: [Album], artist: Artist?) -> some View {
        let look = looks.current
        return ZStack {
            PlayerBackgroundView(song: song, isTall: false)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    PlayerArtworkStage(song: song, side: 104)
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(look.name)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(looks.accent)
                        Text(song.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(song.artist ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Text(song.album ?? song.title)
                            .font(.system(size: 22 * look.lyricsScale, weight: .bold))
                            .foregroundStyle(looks.lyricsHighlight)
                            .shadow(color: looks.lyricsHighlight.opacity(look.lyricsGlow ? 0.45 : 0), radius: 10)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying && player.currentSong != nil ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(looks.accent)
                    .disabled(player.currentSong == nil)
                }

                HStack(spacing: 10) {
                    ForEach(albums) { album in
                        ArtworkView(coverArt: album.coverArt, pointSize: 52)
                            .frame(width: 52, height: 52)
                    }
                    if let artist {
                        ArtworkView(coverArt: artist.coverArt, pointSize: 52, isCircle: true)
                            .frame(width: 52, height: 52)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
        }
        .frame(height: 210)
        .environment(\.colorScheme, .dark)
    }
}
