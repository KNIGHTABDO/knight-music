import SwiftUI

struct RadioStationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryRepository.self) private var library
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let query = library.radioStations()
        let stations = query.value

        Group {
            if !query.isLoaded {
                List {
                    SkeletonRowList(count: 6)
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.margin, bottom: 8, trailing: Theme.margin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if stations.isEmpty {
                EmptyStateView(
                    title: "No Radio Stations",
                    systemImage: "antenna.radiowaves.left.and.right",
                    message: "Add stations in Navidrome"
                )
            } else {
                List(stations) { station in
                    let isPlayingThisStation = player.currentRadio?.id == station.id && player.isPlaying

                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 48, height: 48)

                            if isPlayingThisStation {
                                NowPlayingIndicator(isAnimating: player.isPlaying, color: Theme.accent, size: 20)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.accent)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name)
                                .font(.kmRowTitle)
                                .foregroundStyle(isPlayingThisStation ? Theme.accent : Theme.label)
                                .lineLimit(1)

                            let host = hostString(from: station.homePageUrl)
                            if !host.isEmpty {
                                Text(host)
                                    .font(.kmRowSubtitle)
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.impact(.medium)
                        player.playRadio(station)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Radio Stations")
        .refreshable { await app.pullToRefresh() }
        .observing(query)
    }

    private func hostString(from urlString: String?) -> String {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty else {
            return ""
        }
        if let url = URL(string: urlString), let host = url.host {
            return host
        }
        return urlString
    }
}
