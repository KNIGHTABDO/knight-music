import SwiftUI

/// Queue management view:
/// - Header: "Playing Next", shuffle/repeat glass capsule toggles, "Clear" upcoming button
/// - Collapsible "History" section (last 20 songs) with tap-to-skip
/// - Highlighted "Now Playing" row with animated equalizer indicator
/// - Upcoming reorderable list with always-on drag handles (.editMode active), swipe-to-delete, and tap-to-skip
/// - Transparent background displaying over the player's background
struct QueueView: View {
    @Environment(PlayerEngine.self) private var player

    @State private var isHistoryExpanded = false

    private var historySongs: [Song] {
        Array(player.history.suffix(20))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            List {
                // Collapsed History section
                if !historySongs.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $isHistoryExpanded) {
                            ForEach(Array(historySongs.enumerated()), id: \.offset) { offset, song in
                                historyRow(song: song, offset: offset)
                            }
                        } label: {
                            Text("History (\(historySongs.count))")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.12))
                    }
                }

                // Currently playing song
                if let current = player.currentSong {
                    Section {
                        currentSongRow(current)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.white.opacity(0.12))
                    } header: {
                        Text("Now Playing")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondaryLabel)
                            .textCase(nil)
                    }
                }

                // Upcoming songs with always-on drag handles
                Section {
                    if player.upcoming.isEmpty {
                        Text("No upcoming songs")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondaryLabel)
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(player.upcoming.enumerated()), id: \.element.id) { offset, entry in
                            upcomingRow(entry: entry, offset: offset)
                        }
                        .onMove { source, destination in
                            player.move(fromOffsets: source, toOffset: destination)
                        }
                        .onDelete { indexSet in
                            for offset in indexSet.sorted().reversed() {
                                player.remove(at: offset)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.12))
                    }
                } header: {
                    Text("Upcoming")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryLabel)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
    }

    private var header: some View {
        HStack {
            Text("Playing Next")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.white)

            Spacer()

            // Shuffle and repeat glass capsule toggles
            HStack(spacing: 8) {
                Button {
                    Haptics.impact(.light)
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(player.shuffleEnabled ? Theme.accent : Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    Haptics.impact(.light)
                    player.cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(player.repeatMode != .off ? Theme.accent : Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }

            if !player.upcoming.isEmpty {
                Button("Clear") {
                    Haptics.impact(.light)
                    player.clearUpcoming()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, 10)
    }

    private func currentSongRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: song.coverArt, pointSize: 44, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)

                Text(song.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer()

            NowPlayingIndicator(isAnimating: player.isPlaying, color: Theme.accent, size: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func historyRow(song: Song, offset: Int) -> some View {
        Button {
            let historyStartIndex = player.currentIndex - historySongs.count
            let targetIndex = historyStartIndex + offset
            if targetIndex >= 0 && targetIndex < player.order.count {
                Haptics.impact(.light)
                player.skip(to: targetIndex)
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(coverArt: song.coverArt, pointSize: 44, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)

                    Text(song.artist ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryLabel)
                        .lineLimit(1)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func upcomingRow(entry: QueueEntry, offset: Int) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: entry.song.coverArt, pointSize: 44, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.song.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                Text(entry.song.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.impact(.light)
            player.skip(toUpcomingOffset: offset)
        }
    }
}
