import SwiftUI

/// Album detail screen matching Apple Music / Arpeggi.
struct AlbumDetailView: View {
    let albumId: String

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let albumQuery = library.album(id: albumId)
        let content = albumQuery.value
        let playlists = library.playlists()

        Group {
            if !albumQuery.isLoaded {
                skeletonView
            } else if let album = content.album {
                let moreAlbumsQuery = library.albums(artistId: album.artistId ?? "")
                albumContentView(album: album, songs: content.songs, moreAlbumsQuery: moreAlbumsQuery)
                    .observing(moreAlbumsQuery)
            } else {
                EmptyStateView(
                    title: "Album Not Found",
                    systemImage: "opticaldisc",
                    message: "This album is not available in your library."
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await app.pullToRefresh() }
        .observing(albumQuery)
        .observing(playlists)
    }

    // MARK: - Album Content

    private func albumContentView(album: Album, songs: [Song], moreAlbumsQuery: LiveQuery<[Album]>) -> some View {
        let otherAlbums = moreAlbumsQuery.value.filter { $0.id != album.id }

        return ScrollView {
            VStack(spacing: 0) {
                // Header (scrolls with content)
                headerView(album: album, songs: songs)
                    .padding(.horizontal, Theme.margin)
                    .padding(.top, 8)
                    .padding(.bottom, 24)

                // Track list
                trackListView(album: album, songs: songs)

                // Footer
                footerView(album: album, songs: songs)

                // More by the artist
                if !otherAlbums.isEmpty {
                    ShelfSection(title: "More by \(album.artist ?? "Artist")", items: otherAlbums) { other in
                        NavigationLink(value: Route.album(other.id)) {
                            AlbumTile(album: other)
                        }
                        .buttonStyle(.plain)
                    }
                    .scrollClipDisabled()
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                } else {
                    Spacer().frame(height: 32)
                }
            }
        }
        .toolbar {
            toolbarItems(album: album, songs: songs)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerView(album: Album, songs: [Song]) -> some View {
        if sizeClass == .regular {
            // iPad regular width: artwork left, info + buttons right (HStack)
            HStack(alignment: .bottom, spacing: 28) {
                HeroArtworkView(
                    song: heroSong(for: album, songs: songs),
                    pointSize: 300,
                    cornerRadius: 10
                )
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 7)
                .backgroundExtensionEffect()

                VStack(alignment: .leading, spacing: 8) {
                    albumMetadata(album: album, alignment: .leading)
                    Spacer().frame(height: 12)
                    playbackButtons(songs: songs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // iPhone compact width: large artwork centered (~70% width)
            VStack(alignment: .center, spacing: 14) {
                HeroArtworkView(
                    song: heroSong(for: album, songs: songs),
                    pointSize: 280,
                    cornerRadius: 10
                )
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 7)

                albumMetadata(album: album, alignment: .center)

                playbackButtons(songs: songs)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func albumMetadata(album: Album, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(album.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(alignment == .center ? .center : .leading)

            if let artist = album.artist, !artist.isEmpty {
                if let artistId = album.artistId, !artistId.isEmpty {
                    NavigationLink(value: Route.artist(artistId)) {
                        Text(artist)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                } else {
                    Text(artist)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            let meta = [album.genre, album.year.map(String.init)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " • ")

            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    private func playbackButtons(songs: [Song]) -> some View {
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
    }

    // MARK: - Track List

    private func trackListView(album: Album, songs: [Song]) -> some View {
        let discs = Dictionary(grouping: songs, by: { $0.discNumber ?? 1 })
        let sortedDiscs = discs.keys.sorted()
        let hasMultipleDiscs = sortedDiscs.count > 1

        return LazyVStack(spacing: 0) {
            ForEach(sortedDiscs, id: \.self) { discNumber in
                if hasMultipleDiscs {
                    HStack {
                        Text("Disc \(discNumber)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.secondaryLabel)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.margin)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                }

                let discSongs = discs[discNumber] ?? []
                ForEach(Array(discSongs.enumerated()), id: \.element.id) { index, song in
                    let isPlaying = player.currentSong?.id == song.id
                    let isPaused = isPlaying && !player.isPlaying
                    let isDownloaded = downloads.isDownloaded(song.id)
                    let showsArtist = song.artist != nil && song.artist != album.artist

                    Button {
                        Haptics.selection()
                        if let overallIndex = songs.firstIndex(where: { $0.id == song.id }) {
                            player.play(songs, startAt: overallIndex, shuffle: false)
                        }
                    } label: {
                        SongRow(
                            title: song.title,
                            subtitle: showsArtist ? song.artist : nil,
                            duration: song.durationSeconds,
                            leading: .trackNumber(song.track),
                            isPlaying: isPlaying,
                            isPaused: isPaused,
                            isDownloaded: isDownloaded
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

                    Divider().padding(.leading, Theme.margin + 28 + 12)
                }
            }
        }
    }

    // MARK: - Footer

    private func footerView(album: Album, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let totalSeconds = songs.reduce(0.0) { $0 + $1.durationSeconds }
            Text(KMFormat.songsAndDuration(count: songs.count, seconds: totalSeconds))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryLabel)

            if let created = album.created {
                Text("Released " + created.formatted(date: .long, time: .omitted))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryLabel)
            } else if let year = album.year {
                Text("Released \(year)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.margin)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarItems(album: Album, songs: [Song]) -> some ToolbarContent {
        let isStarred = album.starred != nil
        let songIds = songs.map(\.id)
        let downloadedCount = songIds.filter { downloads.isDownloaded($0) }.count
        let isAllDownloaded = !songs.isEmpty && downloadedCount == songs.count
        let isDownloading = !isAllDownloaded && songIds.contains { id in
            let s = downloads.status(for: id)?.state
            return s == .downloading || s == .queued
        }
        let playlists = library.playlists()

        ToolbarItemGroup(placement: .topBarTrailing) {
            // Heart button (favorite toggle)
            Button {
                Haptics.impact(.light)
                Task {
                    try? await library.toggleStar(.album, id: album.id, currentlyStarred: isStarred)
                }
            } label: {
                Image(systemName: isStarred ? "heart.fill" : "heart")
                    .foregroundStyle(isStarred ? Theme.accent : Theme.label)
            }

            // Download button
            if isAllDownloaded {
                Menu {
                    Button(role: .destructive) {
                        downloads.delete(songIds: songIds)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            } else if isDownloading {
                let progress = songIds.reduce(0.0) { acc, id in
                    if downloads.isDownloaded(id) { return acc + 1.0 }
                    return acc + (downloads.status(for: id)?.progress ?? 0.0)
                } / Double(max(1, songIds.count))

                Button {
                    downloads.cancel(songIds: songIds)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 2)
                            .frame(width: 18, height: 18)
                        Circle()
                            .trim(from: 0, to: max(0.08, progress))
                            .stroke(Theme.accent, lineWidth: 2)
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-90))
                    }
                }
            } else {
                Button {
                    downloads.download(songs: songs)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }

            // ••• Menu
            Menu {
                Button {
                    player.enqueue(songs, next: true)
                    ui.showToast("Playing Next")
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    player.enqueue(songs, next: false)
                    ui.showToast("Added to Queue")
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }

                Divider()

                Menu {
                    if playlists.value.isEmpty {
                        Text("No Playlists Available")
                    } else {
                        ForEach(playlists.value) { pl in
                            Button(pl.name) {
                                Task {
                                    try? await library.addToPlaylist(id: pl.id, songIds: songIds)
                                    ui.showToast("Added to \(pl.name)")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add to a Playlist…", systemImage: "plus")
                }

                if let artistId = album.artistId, !artistId.isEmpty {
                    NavigationLink(value: Route.artist(artistId)) {
                        Label("Go to Artist", systemImage: "person.crop.circle")
                    }
                }

                Divider()

                ShareLink(item: "\(album.name) — \(album.artist ?? "")") {
                    Label("Share Album", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    // MARK: - Helpers

    private func heroSong(for album: Album, songs: [Song]) -> Song {
        if let first = songs.first {
            return first
        }
        return Song(
            id: album.id,
            title: album.name,
            album: album.name,
            albumId: album.id,
            artist: album.artist,
            artistId: album.artistId,
            coverArt: album.coverArt
        )
    }

    private var skeletonView: some View {
        ScrollView {
            VStack(spacing: 20) {
                LoadingShimmer(cornerRadius: 10)
                    .frame(width: 240, height: 240)
                    .padding(.top, 16)

                VStack(spacing: 8) {
                    LoadingShimmer(cornerRadius: 4).frame(width: 180, height: 20)
                    LoadingShimmer(cornerRadius: 4).frame(width: 120, height: 16)
                }

                SkeletonRowList(count: 6)
            }
        }
    }
}
