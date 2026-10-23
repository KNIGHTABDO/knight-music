import Charts
import SwiftUI

/// "Knight Replay": top songs, albums, artists and genres for a month, a year or all time.
struct ReplayView: View {
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var period = ReplayPeriod(scope: .month)

    var body: some View {
        let query = library.replay(period)
        let stats = query.value

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                periodControls

                if !query.isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if stats.isEmpty {
                    emptyState
                        .frame(minHeight: 320)
                } else {
                    summary(stats)
                    if stats.activity.count > 1 { activityChart(stats) }
                    if !stats.topArtists.isEmpty { topArtists(stats.topArtists) }
                    if !stats.topAlbums.isEmpty { topAlbums(stats.topAlbums) }
                    if !stats.topSongs.isEmpty { topSongs(stats.topSongs) }
                    if !stats.topGenres.isEmpty { topGenres(stats.topGenres, total: stats.plays) }
                    sourceFooter(stats.source)
                }
            }
            .padding(.vertical, 12)
            .animation(.smooth, value: stats)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Knight Replay")
        .navigationBarTitleDisplayMode(.large)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .observing(query)
    }

    @ViewBuilder
    private var emptyState: some View {
        if period.scope == .allTime {
            EmptyStateView(
                title: "No Listening History",
                systemImage: "chart.bar.xaxis",
                message: "Songs you play will be counted here."
            )
        } else {
            EmptyStateView(
                title: "No Listening History",
                systemImage: "chart.bar.xaxis",
                message: "Nothing was played in \(period.title). Try an earlier period or All Time.",
                actionTitle: "Show All Time",
                action: { withAnimation(.smooth) { period = ReplayPeriod(scope: .allTime) } }
            )
        }
    }

    // MARK: - Period

    private var periodControls: some View {
        VStack(spacing: 14) {
            Picker("Period", selection: Binding(
                get: { period.scope },
                set: { scope in withAnimation(.smooth) { period = ReplayPeriod(scope: scope) } }
            )) {
                ForEach(ReplayPeriod.Scope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: period.scope)

            if period.scope != .allTime {
                HStack {
                    Button {
                        withAnimation(.smooth) { period.offset -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous \(period.scope == .month ? "Month" : "Year")")

                    Spacer()

                    Text(period.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .contentTransition(.numericText(value: Double(period.offset)))

                    Spacer()

                    Button {
                        withAnimation(.smooth) { period.offset += 1 }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!period.canGoForward)
                    .accessibilityLabel("Next \(period.scope == .month ? "Month" : "Year")")
                }
                .font(.system(size: 17, weight: .semibold))
                .buttonStyle(.borderless)
                .tint(Theme.accent)
                .sensoryFeedback(.selection, trigger: period.offset)
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - Summary

    private func summary(_ stats: ReplayStats) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 4 : 2)
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(value: stats.minutes, label: "Minutes Listened", symbol: "clock")
            StatTile(value: stats.plays, label: "Plays", symbol: "play.circle")
            StatTile(value: stats.songCount, label: stats.songCount == 1 ? "Song" : "Songs", symbol: "music.note")
            StatTile(value: stats.artistCount, label: stats.artistCount == 1 ? "Artist" : "Artists", symbol: "music.mic")
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - Chart

    private func activityChart(_ stats: ReplayStats) -> some View {
        let unit: Calendar.Component = switch period.scope {
        case .month: .day
        case .year: .month
        case .allTime: .year
        }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Listening Activity")
            Chart(stats.activity) { bucket in
                BarMark(x: .value("Date", bucket.date, unit: unit), y: .value("Plays", bucket.plays))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: period.scope == .year ? 12 : 6))
            }
            .frame(height: 170)
            .accessibilityLabel("Plays over time")
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - Top Artists

    private func topArtists(_ artists: [ReplayStats.RankedArtist]) -> some View {
        ShelfSection(title: "Top Artists", items: artists, tileWidth: sizeClass == .regular ? 150 : 120) { ranked in
            let rank = (artists.firstIndex(of: ranked) ?? 0) + 1
            let tile = VStack(spacing: 6) {
                ArtworkView(coverArt: ranked.coverArt, pointSize: 120, isCircle: true, placeholderSymbol: "music.mic")
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .topLeading) { RankBadge(rank: rank) }
                Text(ranked.name)
                    .font(.kmTileTitle)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(Self.playsText(ranked.plays))
                    .font(.kmTileSubtitle)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            if let id = ranked.artistId {
                NavigationLink(value: Route.artist(id)) { tile }
                    .buttonStyle(.plain)
            } else {
                tile
            }
        }
    }

    // MARK: - Top Albums

    private func topAlbums(_ albums: [ReplayStats.RankedAlbum]) -> some View {
        ShelfSection(title: "Top Albums", items: albums) { ranked in
            let rank = (albums.firstIndex(of: ranked) ?? 0) + 1
            NavigationLink(value: Route.album(ranked.album.id)) {
                AlbumTile(
                    coverArt: ranked.album.coverArt,
                    title: ranked.album.name,
                    subtitle: Self.playsText(ranked.plays)
                )
                .overlay(alignment: .topLeading) { RankBadge(rank: rank) }
            }
            .buttonStyle(.plain)
            .contextMenu { AlbumContextMenu(album: ranked.album) }
        }
    }

    // MARK: - Top Songs

    private func topSongs(_ ranked: [ReplayStats.RankedSong]) -> some View {
        let songs = ranked.map(\.song)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Top Songs")
                Spacer()
                Button {
                    Haptics.impact(.medium)
                    player.play(songs, startAt: 0, shuffle: false)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.glass)
            }

            LazyVStack(spacing: 0) {
                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, item in
                    Button {
                        Haptics.selection()
                        player.play(songs, startAt: index, shuffle: false)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(index < 3 ? Theme.accent : Theme.secondaryLabel)
                                .frame(width: 26, alignment: .trailing)
                            ArtworkView(coverArt: item.song.coverArt, pointSize: 48)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.song.title)
                                    .font(.kmRowTitle)
                                    .foregroundStyle(player.currentSong?.id == item.song.id ? Theme.accent : Theme.label)
                                    .lineLimit(1)
                                Text(item.song.artist ?? "")
                                    .font(.kmTileSubtitle)
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(Self.playsText(item.plays))
                                .font(.kmTileSubtitle.monospacedDigit())
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SongActionsMenu(song: item.song) }
                    if index < ranked.count - 1 {
                        Divider().padding(.leading, 98)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - Top Genres

    private func topGenres(_ genres: [ReplayStats.RankedGenre], total: Int) -> some View {
        let top = max(genres.first?.plays ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Top Genres")
            ForEach(genres) { genre in
                NavigationLink(value: Route.genre(genre.name)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(genre.name)
                                .font(.kmRowTitle)
                                .foregroundStyle(Theme.label)
                            Spacer()
                            Text(total > 0 ? "\(Int((Double(genre.plays) / Double(total) * 100).rounded()))%" : "")
                                .font(.kmTileSubtitle.monospacedDigit())
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(Theme.accent.gradient)
                                .frame(width: max(6, geo.size.width * CGFloat(genre.plays) / CGFloat(top)))
                        }
                        .frame(height: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    private func sourceFooter(_ source: ReplayStats.Source) -> some View {
        Text(source == .server
             ? "All Time uses the play counts your server keeps for every client."
             : "Counted from songs played to the end on this device.")
            .font(.footnote)
            .foregroundStyle(Theme.tertiaryLabel)
            .padding(.horizontal, Theme.margin)
    }

    private static func playsText(_ plays: Int) -> String {
        plays == 1 ? "1 play" : "\(plays.formatted()) plays"
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(value.formatted())
                .font(.system(size: 28, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.label)
                .contentTransition(.numericText(value: Double(value)))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.kmTileSubtitle)
                .foregroundStyle(Theme.secondaryLabel)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.secondaryBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct RankBadge: View {
    let rank: Int

    var body: some View {
        Text("\(rank)")
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 24, minHeight: 24)
            .background(rank <= 3 ? Theme.accent : Color.black.opacity(0.6), in: Circle())
            .padding(6)
            .accessibilityLabel("Number \(rank)")
    }
}
