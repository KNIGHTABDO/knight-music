import SwiftUI

/// Title (marquee, opens the album) and artist (opens the artist) for the full player.
struct PlayerSongTitles: View {
    let song: Song
    var titleSize: CGFloat = 22
    var artistSize: CGFloat = 17

    @Environment(UIState.self) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if let albumId = song.albumId { ui.open(.album(albumId)) }
            } label: {
                MarqueeText(text: song.title, font: .system(size: titleSize, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(song.albumId == nil)
            .accessibilityHint(song.albumId == nil ? "" : "Opens the album")

            Button {
                if let artistId = song.artistId { ui.open(.artist(artistId)) }
            } label: {
                MarqueeText(
                    text: song.artist ?? "",
                    font: .system(size: artistSize),
                    color: Color.white.opacity(0.75)
                )
            }
            .buttonStyle(.plain)
            .disabled(song.artistId == nil)
            .accessibilityHint(song.artistId == nil ? "" : "Opens the artist")
        }
        .id(song.id)
        .transition(.opacity)
        .animation(.smooth(duration: 0.25), value: song.id)
    }
}

/// Heart · 5-star rating · ••• row under the player artwork.
struct PlayerSongActionsRow: View {
    let song: Song
    @Binding var rating: Int
    var starSize: CGFloat = 18
    var showsRating = true

    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui

    var body: some View {
        HStack {
            if song.isYouTube {
                Button {
                    Haptics.impact(.medium)
                    YouTubeImporter.addWithFeedback(song, ui: ui)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add to Navidrome")
            } else {
                favoriteButton
            }

            Spacer()

            if showsRating && !song.isYouTube {
                StarRatingView(rating: $rating, starSize: starSize, spacing: 6)
                    .sensoryFeedback(.selection, trigger: rating)
                Spacer()
            }

            Menu {
                SongActionsMenu(song: song)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Song Actions")
        }
    }

    private var favoriteButton: some View {
        Button {
            Haptics.impact(.medium)
            player.toggleStarCurrent()
        } label: {
            Image(systemName: song.starred != nil ? "heart.fill" : "heart")
                .font(.system(size: 20))
                .foregroundStyle(song.starred != nil ? Theme.accent : Color.white.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: song.starred != nil)
        .accessibilityLabel(song.starred != nil ? "Unfavorite" : "Favorite")
    }
}
