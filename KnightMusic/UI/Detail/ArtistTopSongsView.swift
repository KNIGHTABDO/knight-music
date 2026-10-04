import SwiftUI

struct ArtistTopSongsView: View {
    let artistName: String
    let songs: [Song]

    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryRepository.self) private var library

    var body: some View {
        let playlists = library.playlists()

        ScrollView {
            VStack(spacing: 0) {
                // Play / Shuffle glass buttons
                HStack(spacing: 12) {
                    Button {
                        Haptics.impact(.medium)
                        player.play(songs, startAt: 0, shuffle: false)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)

                    Button {
                        Haptics.impact(.medium)
                        player.play(songs, shuffle: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.vertical, 12)

                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            Haptics.selection()
                            player.play(songs, startAt: index, shuffle: false)
                        } label: {
                            SongRow(
                                song: song,
                                showsArtwork: true,
                                isPlaying: player.currentSong?.id == song.id,
                                isPaused: player.currentSong?.id == song.id && !player.isPlaying,
                                isDownloaded: downloads.isDownloaded(song.id)
                            ) {
                                SongActionsMenu(song: song)
                            }
                            .padding(.horizontal, Theme.margin)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            SongActionsMenu(song: song)
                        }

                        Divider().padding(.leading, Theme.margin + 48 + 12)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.large)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .observing(playlists)
    }
}
