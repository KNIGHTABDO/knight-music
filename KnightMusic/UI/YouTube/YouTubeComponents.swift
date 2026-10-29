import SwiftUI

extension YTItem: CoverArtProviding {
    var coverArtId: String? {
        switch self {
        case .song(let s): s.thumbnail
        case .album(let a): a.thumbnail
        case .artist(let a): a.thumbnail
        case .playlist(let p): p.thumbnail
        }
    }
}

extension YTBrowseTarget {
    func gridRoute(title: String) -> Route { .youTubeGrid(browseId: browseId, params: params, title: title) }
    func songsRoute(title: String) -> Route { .youTubeSongs(browseId: browseId, params: params, title: title) }

    func destinationRoute(title: String) -> Route {
        if browseId == "FEmusic_moods_and_genres" {
            return .youTubeMoodsAndGenres
        }
        if browseId.hasPrefix("FEmusic_moods_and_genres_category") || (browseId.hasPrefix("FE") && params != nil && browseId != "FEmusic_home") {
            return .youTubeCategory(browseId: browseId, params: params, title: title)
        }
        if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
            return .playlist(Song.youTubePrefix + browseId)
        }
        if browseId.hasPrefix("MPRE") {
            return .album(Song.youTubePrefix + browseId)
        }
        if browseId.hasPrefix("UC") {
            return .artist(Song.youTubePrefix + browseId)
        }
        return gridRoute(title: title)
    }
}

extension YTArtistRef {
    var route: Route? { browseId.map { .artist(Song.youTubePrefix + $0) } }
}

/// Loads one YouTube Music page and shows it, with a skeleton while loading and a retry on failure.
struct YTLoader<Value: Sendable, Content: View>: View {
    let id: String
    let load: @Sendable () async throws -> Value
    @ViewBuilder let content: (Value) -> Content

    @State private var value: Value?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let errorMessage {
                EmptyStateView(title: "Couldn't Load", systemImage: "exclamationmark.triangle", message: errorMessage,
                               actionTitle: "Try Again") {
                    self.errorMessage = nil
                    Task { await fetch() }
                }
            } else {
                ScrollView { SkeletonRowList(count: 8).padding(.top, 16) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: id) {
            if value == nil { await fetch() }
        }
    }

    private func fetch() async {
        do {
            let loaded = try await load()
            withAnimation(.smooth(duration: 0.2)) { value = loaded }
        } catch is CancellationError {
        } catch {
            Log.api.warning("YouTube Music page \(id) failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}

/// An album, artist, playlist or song/video tile. Tapping a song starts a radio from it, like YouTube Music.
struct YTItemTile: View {
    let item: YTItem

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        switch item {
        case .song(let s):
            Button {
                Haptics.impact(.medium)
                Task { await player.startStation(from: s.song) }
            } label: {
                AlbumTile(coverArt: s.thumbnail, title: s.title, subtitle: s.artistLine)
            }
            .buttonStyle(.plain)
            .contextMenu { SongActionsMenu(song: s.song) }
        case .album(let a):
            NavigationLink(value: Route.album(Song.youTubePrefix + a.browseId)) {
                AlbumTile(coverArt: a.thumbnail, title: a.title, subtitle: a.subtitle)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let shareURL = URL(string: "https://music.youtube.com/browse/\(a.browseId)") {
                    ShareLink(item: shareURL) {
                        Label("Share Album", systemImage: "square.and.arrow.up")
                    }
                }
            }
        case .artist(let a):
            NavigationLink(value: Route.artist(Song.youTubePrefix + a.browseId)) {
                AlbumTile(coverArt: a.thumbnail, title: a.name, subtitle: a.subtitle ?? "Artist", isCircle: true)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let shareURL = URL(string: "https://music.youtube.com/channel/\(a.browseId)") {
                    ShareLink(item: shareURL) {
                        Label("Share Artist", systemImage: "square.and.arrow.up")
                    }
                }
            }
        case .playlist(let p):
            NavigationLink(value: Route.playlist(Song.youTubePrefix + p.browseId)) {
                AlbumTile(coverArt: p.thumbnail, title: p.title, subtitle: p.subtitle)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let shareURL = URL(string: "https://music.youtube.com/playlist?list=\(p.browseId)") {
                    ShareLink(item: shareURL) {
                        Label("Share Playlist", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

/// Song lines for YouTube Music lists; tapping one plays the list from there.
struct YTSongList: View {
    let songs: [Song]
    var numbered = false

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                Button {
                    Haptics.selection()
                    player.play(songs, startAt: index, shuffle: false)
                } label: {
                    SongRow(title: song.title, subtitle: song.artist, duration: song.durationSeconds,
                            leading: numbered ? .trackNumber(index + 1) : .artwork(song.coverArt),
                            isPlaying: player.currentSong?.id == song.id, isPaused: !player.isPlaying) {
                        SongActionsMenu(song: song)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, Theme.margin)
                }
                .buttonStyle(.plain)
                .contextMenu { SongActionsMenu(song: song) }

                if index < songs.count - 1 {
                    Divider().padding(.leading, numbered ? Theme.margin + 40 : 76)
                }
            }
        }
    }
}

/// Artwork, title, linked subtitle, details and Play / Shuffle for a YouTube Music album or playlist.
struct YTCollectionHeader: View {
    let title: String
    var subtitle: String?
    var subtitleRoute: Route?
    var detail: String?
    var thumbnail: String?
    let songs: [Song]

    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .bottom, spacing: 28) {
                artwork(300)
                    .backgroundExtensionEffect()
                VStack(alignment: .leading, spacing: 8) {
                    metadata(alignment: .leading)
                    Spacer().frame(height: 12)
                    buttons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 14) {
                artwork(280)
                metadata(alignment: .center)
                buttons.padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func artwork(_ size: CGFloat) -> some View {
        ArtworkView(coverArt: thumbnail, pointSize: size, cornerRadius: 10)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 9)
    }

    private func metadata(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.system(size: sizeClass == .regular ? 30 : 26, weight: .bold))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            if let subtitle, !subtitle.isEmpty {
                if let subtitleRoute {
                    NavigationLink(value: subtitleRoute) {
                        Text(subtitle).font(.system(size: 20)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(subtitle).font(.system(size: 20)).foregroundStyle(Theme.accent)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Label("YouTube Music", systemImage: "play.rectangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiaryLabel)
        }
    }

    private var buttons: some View {
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
        .disabled(songs.isEmpty)
    }
}

/// A titled horizontal shelf of YouTube Music tiles.
struct YTShelfView: View {
    let shelf: YTShelf
    var onHeaderTap: (() -> Void)? = nil

    var body: some View {
        ShelfSection(
            title: shelf.title,
            subtitle: shelf.strapline,
            items: shelf.items,
            headerRoute: shelf.more?.destinationRoute(title: shelf.title),
            onHeaderTap: onHeaderTap
        ) { item in
            YTItemTile(item: item)
        }
        .scrollClipDisabled()
    }
}

/// Apple Music-style paged columns of four song rows for YouTube Music discover / charts shelves.
struct YTSongColumnsShelf: View {
    let shelf: YTShelf
    var onHeaderTap: (() -> Void)? = nil

    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let songs: [Song] = shelf.items.compactMap { if case .song(let s) = $0 { return s.song } else { return nil } }
        let columnWidth: CGFloat = sizeClass == .regular ? 340 : 300
        let rowCount = min(4, max(songs.count, 1))

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: shelf.title,
                route: shelf.more?.destinationRoute(title: shelf.title),
                action: onHeaderTap
            )
            .padding(.horizontal, Theme.margin)

            if let strapline = shelf.strapline, !strapline.isEmpty {
                Text(strapline)
                    .font(.kmTileSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding(.horizontal, Theme.margin)
                    .padding(.top, -6)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 4), count: rowCount), spacing: 18) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
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

/// Renders a YTShelf using the appropriate visual style (carousel or song columns).
struct YTShelfItemDispatcher: View {
    let shelf: YTShelf
    var onHeaderTap: (() -> Void)? = nil

    var body: some View {
        switch shelf.style {
        case .songColumns:
            YTSongColumnsShelf(shelf: shelf, onHeaderTap: onHeaderTap)
        case .carousel, .moodStrip:
            YTShelfView(shelf: shelf, onHeaderTap: onHeaderTap)
        }
    }
}
