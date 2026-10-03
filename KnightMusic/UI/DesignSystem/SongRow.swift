import SwiftUI

/// A song line: [artwork | track number] title / artist ... duration, download badge, ••• menu.
/// The row is plain content; wrap it in a Button / NavigationLink for tap handling.
struct SongRow<MenuContent: View>: View {
    enum Leading {
        case artwork(String?)
        case trackNumber(Int?)
        case none
    }

    var title: String
    var subtitle: String?
    var duration: TimeInterval?
    var leading: Leading
    var isPlaying: Bool
    var isPaused: Bool
    var isDownloaded: Bool
    var isExplicitlyDimmed: Bool
    var menu: MenuContent

    init(title: String, subtitle: String? = nil, duration: TimeInterval? = nil, leading: Leading = .none,
         isPlaying: Bool = false, isPaused: Bool = false, isDownloaded: Bool = false, isDimmed: Bool = false,
         @ViewBuilder menu: () -> MenuContent) {
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.leading = leading
        self.isPlaying = isPlaying
        self.isPaused = isPaused
        self.isDownloaded = isDownloaded
        self.isExplicitlyDimmed = isDimmed
        self.menu = menu()
    }

    init(song: Song, showsArtwork: Bool = true, isPlaying: Bool = false, isPaused: Bool = false,
         isDownloaded: Bool = false, @ViewBuilder menu: () -> MenuContent) {
        self.init(title: song.title, subtitle: song.artist, duration: song.durationSeconds,
                  leading: showsArtwork ? .artwork(song.coverArt) : .trackNumber(song.track),
                  isPlaying: isPlaying, isPaused: isPaused, isDownloaded: isDownloaded, menu: menu)
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingView
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.kmRowTitle)
                    .foregroundStyle(isPlaying ? Theme.accent : Theme.label)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.kmRowSubtitle)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .accessibilityLabel("Downloaded")
            }
            if let duration {
                Text(KMFormat.duration(duration))
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(Theme.secondaryLabel)
            }
            if MenuContent.self != EmptyView.self {
                Menu { menu } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                }
            }
        }
        .opacity(isExplicitlyDimmed ? 0.45 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .artwork(let id):
            ArtworkView(coverArt: id, pointSize: 48, cornerRadius: 6)
                .overlay {
                    if isPlaying {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                        NowPlayingIndicator(isAnimating: !isPaused, color: .white, size: 18)
                    }
                }
        case .trackNumber(let n):
            ZStack {
                if isPlaying {
                    NowPlayingIndicator(isAnimating: !isPaused)
                } else {
                    Text(n.map(String.init) ?? "–")
                        .font(.system(size: 17).monospacedDigit())
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            .frame(width: 28)
        case .none:
            if isPlaying { NowPlayingIndicator(isAnimating: !isPaused).frame(width: 28) }
        }
    }
}

extension SongRow where MenuContent == EmptyView {
    init(title: String, subtitle: String? = nil, duration: TimeInterval? = nil, leading: Leading = .none,
         isPlaying: Bool = false, isPaused: Bool = false, isDownloaded: Bool = false, isDimmed: Bool = false) {
        self.init(title: title, subtitle: subtitle, duration: duration, leading: leading, isPlaying: isPlaying,
                  isPaused: isPaused, isDownloaded: isDownloaded, isDimmed: isDimmed) { EmptyView() }
    }

    init(song: Song, showsArtwork: Bool = true, isPlaying: Bool = false, isPaused: Bool = false, isDownloaded: Bool = false) {
        self.init(song: song, showsArtwork: showsArtwork, isPlaying: isPlaying, isPaused: isPaused, isDownloaded: isDownloaded) { EmptyView() }
    }
}
