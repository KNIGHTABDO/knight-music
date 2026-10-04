import SwiftUI

/// Queue management view:
/// - Header: "Playing Next" with Reorder/Clear, then Shuffle · Repeat · AutoMix glass toggles
/// - Collapsible "History" section (last 20 songs) with tap-to-skip
/// - Highlighted "Now Playing" row with animated equalizer indicator
/// - Upcoming reorderable list with always-on drag handles (.editMode active), swipe-to-delete, and tap-to-skip
/// - Transparent background displaying over the player's background
struct QueueView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings

    @State private var isHistoryExpanded = false
    @State private var isReordering = false

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
                        .listRowSeparator(.hidden)
                    }
                }

                // Currently playing song
                if let current = player.currentSong {
                    Section {
                        currentSongRow(current)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        Text("Now Playing")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondaryLabel)
                            .textCase(nil)
                    }
                }

                // Upcoming songs with reordering when toggled, and swipe-to-delete
                Section {
                    if player.upcoming.isEmpty {
                        Text("No upcoming songs")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondaryLabel)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
                        .listRowSeparator(.hidden)
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
            .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Playing Next")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)

                Spacer()

                if !player.upcoming.isEmpty {
                    Button(isReordering ? "Done" : "Reorder") {
                        Haptics.impact(.light)
                        withAnimation(.smooth) {
                            isReordering.toggle()
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isReordering ? Theme.accent : Color.white.opacity(0.85))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button("Clear") {
                        Haptics.impact(.light)
                        player.clearUpcoming()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }

            // Shuffle · Repeat · AutoMix, as in Apple Music's queue
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    queueToggle(systemImage: "shuffle", title: "Shuffle", isOn: player.shuffleEnabled) {
                        player.toggleShuffle()
                    }
                    queueToggle(systemImage: player.repeatMode == .one ? "repeat.1" : "repeat", title: "Repeat",
                                isOn: player.repeatMode != .off) {
                        player.cycleRepeat()
                    }
                    queueToggle(systemImage: "waveform.path", title: "AutoMix", isOn: settings.autoMixEnabled) {
                        settings.autoMixEnabled.toggle()
                    }
                    .accessibilityHint("Blends songs into each other with beat-matched transitions")
                }
            }
        }
        .padding(.horizontal, Theme.margin + 4)
        .padding(.vertical, 10)
    }

    private func queueToggle(systemImage: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isOn ? Theme.accent : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .regular.tint(Theme.accent.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func currentSongRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: song.coverArt, pointSize: 44, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .layoutPriority(1)

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
        .listRowSeparator(.hidden)
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
                        .layoutPriority(1)

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
        .listRowSeparator(.hidden)
    }

    private func upcomingRow(entry: QueueEntry, offset: Int) -> some View {
        HStack(spacing: 12) {
            ArtworkView(coverArt: entry.song.coverArt, pointSize: 44, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.song.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(entry.song.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer()

            if !isReordering {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isReordering else { return }
            Haptics.impact(.light)
            player.skip(toUpcomingOffset: offset)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Haptics.impact(.light)
                player.remove(at: offset)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .listRowSeparator(.hidden)
    }
}
