import SwiftUI

/// Big "Top Picks" card: cover on top, a panel in the cover's own colour with the reason it was picked.
struct TopPickCard: View {
    let album: Album
    let reason: String
    var width: CGFloat

    @State private var palette: ArtworkPalette?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(coverArt: album.coverArt, pointSize: width, cornerRadius: 0)
                .frame(width: width, height: width)
            VStack(alignment: .leading, spacing: 3) {
                Text(reason.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(album.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(album.artist ?? " ")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background((palette ?? ArtworkPalette.cachedPalette(for: album.coverArt) ?? .fallback).primary)
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: album.coverArt) {
            let found = await ArtworkPalette.palette(for: album.coverArt)
            withAnimation(.smooth) { palette = found }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Apple Music-style paged columns of three song rows ("Continue Listening").
struct SongColumnsShelf: View {
    let title: String
    let songs: [Song]
    var route: Route?

    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let columnWidth: CGFloat = sizeClass == .regular ? 340 : 300
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, route: route)
                .padding(.horizontal, Theme.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 4), count: min(3, max(songs.count, 1))), spacing: 18) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            Haptics.impact(.light)
                            player.play(songs, startAt: index, shuffle: false)
                        } label: {
                            SongRow(
                                song: song,
                                isPlaying: player.currentSong?.id == song.id,
                                isPaused: !player.isPlaying
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: columnWidth)
                        .contextMenu { SongActionsMenu(song: song) }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Theme.margin, for: .scrollContent)
            .scrollClipDisabled()
        }
    }
}

/// One album shelf per genre; owns its live query so the Home body stays flat.
struct GenreShelf: View {
    let genre: String

    @Environment(LibraryRepository.self) private var library

    var body: some View {
        let albums = library.genreShelf(genre)
        Group {
            if albums.value.count >= 3 {
                ShelfSection(title: genre, items: albums.value, headerRoute: .genre(genre)) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        AlbumTile(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { AlbumContextMenu(album: album) }
                }
                .scrollClipDisabled()
            }
        }
        .observing(albums)
    }
}

/// Circular server/user badge in the Home toolbar: switch servers or jump to Settings.
struct AccountAvatarMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(UIState.self) private var ui: UIState?

    var body: some View {
        Menu {
            if let account = app.activeAccount {
                Section("\(account.username) on \(account.name)") {
                    ForEach(app.accounts.accounts.filter { $0.id != account.id }, id: \.id) { other in
                        Button {
                            Haptics.selection()
                            app.switchAccount(id: other.id)
                        } label: {
                            Label("Switch to \(other.name)", systemImage: "server.rack")
                        }
                    }
                }
            }
            Button {
                ui?.selectedTab = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Text(initials)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accent.gradient))
        }
        .accessibilityLabel("Account")
    }

    private var initials: String {
        let source = app.activeAccount?.username ?? app.activeAccount?.name ?? "K"
        return String(source.prefix(1)).uppercased()
    }
}
