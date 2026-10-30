import ActivityKit
import SwiftUI
import WidgetKit

public struct MusicRecognitionLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: MusicRecognitionAttributes.self) { context in
            // Lock Screen / Top banner presentation
            HStack(spacing: 12) {
                switch context.state.phase {
                case .matched(let title, let artist, let artworkURL, let localSongId):
                    Link(destination: deepLinkURL(songId: localSongId)) {
                        HStack(spacing: 12) {
                            if let artworkURL, let url = URL(string: artworkURL) {
                                AsyncImage(url: url) { phase in
                                    if let img = phase.image {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color.gray.opacity(0.3)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                fallbackArtwork(size: 48)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(artist)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(Color(white: 0.7))
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(white: 0.5))
                        }
                    }
                case .listening:
                    HStack(spacing: 12) {
                        Image(systemName: "shazam.logo.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Listening for music...")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Knight Music")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Color(white: 0.7))
                        }

                        Spacer()

                        Image(systemName: "waveform")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.blue)
                    }
                case .notFound:
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("No Match Found")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                case .error(let msg):
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded View (matching IMG_0059.jpg)
                DynamicIslandExpandedRegion(.leading) {
                    switch context.state.phase {
                    case .matched(_, _, let artworkURL, _):
                        if let artworkURL, let url = URL(string: artworkURL) {
                            AsyncImage(url: url) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.gray.opacity(0.3)
                                }
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.leading, 8)
                            .padding(.top, 4)
                        } else {
                            fallbackArtwork(size: 52)
                                .padding(.leading, 8)
                                .padding(.top, 4)
                        }
                    case .listening:
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.2)).frame(width: 44, height: 44)
                            Image(systemName: "shazam.logo.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.blue)
                        }
                        .padding(.leading, 8)
                    default:
                        Image(systemName: "waveform.badge.exclamationmark")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    switch context.state.phase {
                    case .matched(let title, let artist, _, _):
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(artist)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Color(white: 0.7))
                                .lineLimit(1)
                        }
                        .padding(.leading, 6)
                        .padding(.top, 4)
                    case .listening:
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Listening for music...")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Knight Music")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Color(white: 0.7))
                        }
                        .padding(.leading, 6)
                    case .notFound:
                        Text("No Match Found")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.leading, 6)
                    case .error(let message):
                        Text(message)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .padding(.leading, 6)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    switch context.state.phase {
                    case .matched(_, _, _, let localSongId):
                        Link(destination: deepLinkURL(songId: localSongId)) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(white: 0.5))
                                .padding(.trailing, 8)
                        }
                    case .listening:
                        Image(systemName: "waveform")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.blue)
                            .padding(.trailing, 8)
                    default:
                        EmptyView()
                    }
                }
            } compactLeading: {
                switch context.state.phase {
                case .matched(_, _, let artworkURL, _):
                    if let artworkURL, let url = URL(string: artworkURL) {
                        AsyncImage(url: url) { phase in
                            if let img = phase.image {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.blue
                            }
                        }
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.blue)
                    }
                case .listening:
                    Image(systemName: "shazam.logo.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.blue)
                default:
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } compactTrailing: {
                switch context.state.phase {
                case .matched(let title, _, _, _):
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 85)
                        .lineLimit(1)
                case .listening:
                    Image(systemName: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blue)
                default:
                    EmptyView()
                }
            } minimal: {
                Image(systemName: "shazam.logo.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.blue)
            }
        }
    }

    private func fallbackArtwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.2))
                .frame(width: size, height: size)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.45))
                .foregroundStyle(.white)
        }
    }

    private func deepLinkURL(songId: String?) -> URL {
        if let songId, !songId.isEmpty {
            return URL(string: "knightmusic://song/\(songId)") ?? URL(string: "knightmusic://recognize")!
        }
        return URL(string: "knightmusic://recognize")!
    }
}
