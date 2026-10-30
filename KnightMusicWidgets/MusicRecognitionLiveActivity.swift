import ActivityKit
import SwiftUI
import WidgetKit

public struct MusicRecognitionLiveActivity: Widget {
    private let appGroupIdentifier = "group.com.knightabdo.knightmusic"

    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: MusicRecognitionAttributes.self) { context in
            // Lock Screen / Top banner presentation
            HStack(spacing: 12) {
                switch context.state.phase {
                case .matched(let title, let artist, _, let artworkFileName, let localSongId):
                    Link(destination: deepLinkURL(songId: localSongId)) {
                        HStack(spacing: 12) {
                            artworkView(filename: artworkFileName, size: 48, cornerRadius: 8)

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
                            .font(.system(size: 16))
                            .foregroundStyle(Color.blue)
                    }
                case .notFound:
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.badge.exclamationmark")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text("No Match Found")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                case .error(let message):
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.yellow)
                        Text(message)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded View (matching IMG_0059.jpg pixel-perfect)
                DynamicIslandExpandedRegion(.leading) {
                    switch context.state.phase {
                    case .matched(_, _, _, let artworkFileName, _):
                        artworkView(filename: artworkFileName, size: 52, cornerRadius: 12)
                            .padding(.leading, 8)
                            .padding(.top, 4)
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
                    case .matched(let title, let artist, _, _, _):
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
                    case .matched:
                        EmptyView()
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
                case .matched(_, _, _, let artworkFileName, _):
                    artworkView(filename: artworkFileName, size: 18, cornerRadius: 4)
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
                case .matched(let title, _, _, _, _):
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
                switch context.state.phase {
                case .matched(_, _, _, let artworkFileName, _):
                    artworkView(filename: artworkFileName, size: 14, cornerRadius: 3)
                default:
                    Image(systemName: "shazam.logo.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.blue)
                }
            }
            .widgetURL(deepLinkURL(songId: context.state.localSongId))
        }
    }

    @ViewBuilder
    private func artworkView(filename: String?, size: CGFloat, cornerRadius: CGFloat) -> some View {
        if let filename,
           let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier),
           let uiImage = UIImage(contentsOfFile: sharedContainer.appendingPathComponent(filename).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallbackArtwork(size: size, cornerRadius: cornerRadius)
        }
    }

    private func fallbackArtwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
