import SwiftUI

/// Apple Music style mini player accessory shown in the bottom bar.
struct MiniPlayerView: View {
    var namespace: Namespace.ID

    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isInline: Bool {
        placement == .inline
    }

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                // Artwork 40pt (6pt radius)
                ArtworkView(coverArt: song.coverArt, pointSize: 40, cornerRadius: 6)
                    .matchedTransitionSource(id: "nowPlayingArtwork", in: namespace)

                // Title + Artist
                if isInline {
                    Text(song.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let artist = song.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryLabel)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Spacer(minLength: 8)

                // Controls
                HStack(spacing: sizeClass == .regular ? 24 : 18) {
                    if !isInline && sizeClass == .regular {
                        Button {
                            player.shuffleEnabled.toggle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(player.shuffleEnabled ? Theme.accent : Theme.secondaryLabel)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !isInline {
                        Button {
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.label)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        Haptics.impact(.medium)
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !isInline && sizeClass == .regular {
                        Button {
                            player.cycleRepeat()
                        } label: {
                            Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(player.repeatMode != .off ? Theme.accent : Theme.secondaryLabel)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .contentShape(Rectangle())
            .onTapGesture {
                ui.isPlayerPresented = true
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height < -20 && abs(value.translation.height) > abs(value.translation.width) {
                            ui.isPlayerPresented = true
                        }
                    }
            )
        }
    }
}
