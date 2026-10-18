import SwiftUI
import WidgetKit

struct KickLiveWidgetView: View {
    let entry: KickLiveEntry
    @Environment(\.widgetFamily) private var family

    private var live: [KickStreamer] { entry.state.snapshot?.live ?? [] }
    private var maxRows: Int { family == .systemLarge ? 10 : 4 }
    private var shown: [KickStreamer] { Array(live.prefix(maxRows)) }
    private var hiddenCount: Int { max(0, live.count - maxRows) }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 6 : 4) {
            header
            if live.isEmpty {
                Spacer(minLength: 0)
                Text("Nobody's live right now")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 2 : 3) {
                    ForEach(shown) { row($0) }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .widgetURL(live.first?.url)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle().fill(KickColors.green).frame(width: 7, height: 7)
            Text("KICK")
                .font(.system(size: 15, weight: .heavy))
            Spacer(minLength: 4)
            Text("\(live.count) live")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KickColors.green)
                .lineLimit(1)
            Button(intent: RefreshKickLiveIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(_ streamer: KickStreamer) -> some View {
        let content = HStack(spacing: 6) {
            Circle().fill(KickColors.green).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(streamer.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if family == .systemMedium, let category = streamer.category {
                        Text(category)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if family == .systemLarge, let subtitle = subtitle(for: streamer) {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(KickFormat.viewers(streamer.viewers))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Small widgets support only one tap target (widgetURL), so rows link only in medium/large.
        if family == .systemSmall {
            content
        } else {
            Link(destination: streamer.url) { content }
        }
    }

    private func subtitle(for streamer: KickStreamer) -> String? {
        let uptime = streamer.startedAt.map { KickFormat.uptime(since: $0, now: entry.date) }
        let parts = [streamer.category, uptime].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                moreText
                Spacer(minLength: 4)
                statusText
            }
            VStack(alignment: .leading, spacing: 0) {
                moreText
                statusText
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var moreText: some View {
        if hiddenCount > 0 {
            Text("+\(hiddenCount) more live")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        let fetchedAt = entry.state.snapshot.map { KickFormat.clock($0.fetchedAt) }
        if entry.state.isOffline {
            Text(fetchedAt.map { "⚠︎ Offline · last \($0)" } ?? "⚠︎ Offline")
                .foregroundStyle(KickColors.amber)
        } else if let fetchedAt {
            Text("Updated \(fetchedAt)")
        }
    }
}

enum KickColors {
    static let green = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x53 / 255, green: 0xFC / 255, blue: 0x18 / 255, alpha: 1)
            : UIColor(red: 0x17 / 255, green: 0xA8 / 255, blue: 0x0B / 255, alpha: 1)
    })

    static let amber = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.76, blue: 0.03, alpha: 1)
            : UIColor(red: 0.72, green: 0.47, blue: 0, alpha: 1)
    })
}
