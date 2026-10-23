import SwiftUI

/// Album detail screen matching Apple Music / Arpeggi.
struct AlbumDetailView: View {
    let albumId: String

    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(UIState.self) private var ui
    @Environment(HermesService.self) private var hermes: HermesService?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection = SongSelection()

    var body: some View {
        let albumQuery = library.album(id: albumId)
        let content = albumQuery.value

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
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await app.pullToRefresh() }
        .observing(albumQuery)
    }

    // MARK: - Album Content

    private func albumContentView(album: Album, songs: [Song], moreAlbumsQuery: LiveQuery<[Album]>) -> some View {
        let otherAlbums = moreAlbumsQuery.value.filter { $0.id != album.id }
        let discs = Dictionary(grouping: songs, by: { $0.discNumber ?? 1 })
        let discNumbers = discs.keys.sorted()

        return List {
            headerView(album: album, songs: songs)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.margin, bottom: 0, trailing: Theme.margin))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(discNumbers, id: \.self) { disc in
                Section {
                    ForEach(discs[disc] ?? []) { song in
                        trackRow(song, album: album, songs: songs)
                    }
                } header: {
                    if discNumbers.count > 1 {
                        Label("Disc \(disc)", systemImage: "opticaldisc")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.secondaryLabel)
                            .padding(.top, 8)
                    }
                }
            }

            footerView(album: album, songs: songs)
                .listRowInsets(EdgeInsets(top: 20, leading: Theme.margin, bottom: 16, trailing: Theme.margin))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if !otherAlbums.isEmpty {
                ShelfSection(title: "More by \(album.artist ?? "Artist")", items: otherAlbums,
                             headerRoute: album.artistId.map { Route.artist($0) }) { other in
                    NavigationLink(value: Route.album(other.id)) {
                        AlbumTile(album: other)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { AlbumContextMenu(album: other) }
                }
                .scrollClipDisabled()
                .padding(.bottom, 32)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) { AlbumBackdrop(coverArt: album.coverArt) }
        .toolbar {
            toolbarItems(album: album, songs: songs)
        }
        .songSelection(selection, songs: songs)
    }

    // MARK: - Header

    @ViewBuilder
    private func headerView(album: Album, songs: [Song]) -> some View {
        if sizeClass == .regular {
            // iPad: artwork left, info + buttons right
            HStack(alignment: .bottom, spacing: 28) {
                HeroArtworkView(
                    song: heroSong(for: album, songs: songs),
                    pointSize: 300,
                    cornerRadius: 10
                )
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 9)
                .backgroundExtensionEffect()

                VStack(alignment: .leading, spacing: 8) {
                    albumMetadata(album: album, songs: songs, alignment: .leading)
                    Spacer().frame(height: 12)
                    playbackButtons(songs: songs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // iPhone: large centred artwork
            VStack(alignment: .center, spacing: 14) {
                HeroArtworkView(
                    song: heroSong(for: album, songs: songs),
                    pointSize: 280,
                    cornerRadius: 10
                )
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 9)

                albumMetadata(album: album, songs: songs, alignment: .center)

                playbackButtons(songs: songs)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func albumMetadata(album: Album, songs: [Song], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(album.name)
                .font(.system(size: sizeClass == .regular ? 30 : 26, weight: .bold))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(alignment == .center ? .center : .leading)

            if let artist = album.artist, !artist.isEmpty {
                if let artistId = album.artistId, !artistId.isEmpty {
                    NavigationLink(value: Route.artist(artistId)) {
                        Text(artist)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(artist)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.accent)
                }
            }

            let meta = [album.genre?.uppercased(), album.year.map(String.init)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")

            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            if let badge = AudioQualityBadge(songs: songs) {
                QualityBadge(badge: badge)
                    .padding(.top, 4)
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

    private func trackRow(_ song: Song, album: Album, songs: [Song]) -> some View {
        let isPlaying = player.currentSong?.id == song.id
        let showsArtist = song.artist != nil && song.artist != album.artist

        return Button {
            if selection.isActive {
                selection.toggle(song.id)
                return
            }
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
                isPaused: isPlaying && !player.isPlaying,
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
        .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.hairline)
    }

    // MARK: - Footer

    private func footerView(album: Album, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let released = releaseText(album) {
                Text(released)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            let totalSeconds = songs.reduce(0.0) { $0 + $1.durationSeconds }
            Text(KMFormat.songsAndDuration(count: songs.count, seconds: totalSeconds))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)

            let labels = (album.recordLabels ?? []).map(\.name).filter { !$0.isEmpty }
            if !labels.isEmpty {
                Text(labels.joined(separator: ", "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            if let created = album.created {
                Text("Added " + created.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "October 4, 2019" from the tagged release date; just the year when that's all the tags say.
    private func releaseText(_ album: Album) -> String? {
        if let release = album.releaseDate, let date = release.date {
            if release.month != nil, release.day != nil {
                return date.formatted(date: .long, time: .omitted)
            }
            if release.month != nil {
                return date.formatted(.dateTime.month(.wide).year())
            }
            return release.year.map(String.init)
        }
        return album.year.map(String.init)
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
                            .stroke(Theme.label.opacity(0.2), lineWidth: 2)
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

                if hermes?.settings.isConfigured == true {
                    Button {
                        let artist = album.artist ?? ""
                        ui.askKnight("Add the full album \(album.name) by \(artist) — only the tracks I'm missing")
                    } label: {
                        Label("Complete this album", systemImage: "sparkles")
                    }

                    Divider()
                }

                Button {
                    ui.playlistPicker = PlaylistPickerRequest(songs: songs, suggestedName: album.name)
                } label: {
                    Label("Add to a Playlist…", systemImage: "text.badge.plus")
                }

                if let first = songs.first {
                    Button {
                        Task { await player.startStation(from: first) }
                    } label: {
                        Label("Start Station", systemImage: "dot.radiowaves.left.and.right")
                    }
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
