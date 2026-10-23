import SwiftUI

struct ArtistTopSongsView: View {
    let artistName: String
    let songs: [Song]

    var body: some View {
        SongCollectionList(songs: songs)
            .navigationTitle(artistName)
            .navigationBarTitleDisplayMode(.large)
    }
}

/// Play / Shuffle buttons over a plain song list with swipe actions and multi-select.
struct SongCollectionList: View {
    let songs: [Song]

    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var selection = SongSelection()

    var body: some View {
        List {
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
            .listRowInsets(EdgeInsets(top: 12, leading: Theme.margin, bottom: 12, trailing: Theme.margin))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                Button {
                    if selection.isActive {
                        selection.toggle(song.id)
                        return
                    }
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
                    .selectable(song.id, in: selection)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    SongActionsMenu(song: song)
                }
                .songSwipeActions(song)
                .listRowInsets(EdgeInsets(top: 6, leading: Theme.margin, bottom: 6, trailing: Theme.margin))
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.hairline)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .scrollEdgeEffectStyle(.soft, for: .top)
        .songSelection(selection, songs: songs)
    }
}
