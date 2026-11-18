import ActivityKit
import SwiftUI
import WidgetKit

private let brandRed = Color(red: 250 / 255, green: 45 / 255, blue: 72 / 255)

/// Download batch progress on the lock screen and in the Dynamic Island (driven by TransferActivityController).
public struct TransferLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            TransferLockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "knightmusic://downloads"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TransferGlyph(state: state, size: 36)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.isFinished ? "Done" : "\(state.completed)/\(state.total)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(state.failed > 0 && state.isFinished ? .orange : .white)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.headline)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let title = state.currentTitle, !state.isFinished {
                            Text(state.currentArtist.map { "\(title) · \($0)" } ?? title)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ProgressView(value: state.fraction)
                            .tint(brandRed)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.isFinished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(brandRed)
            } compactTrailing: {
                if state.isFinished {
                    Text("\(state.completed)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                } else {
                    ProgressView(value: state.fraction)
                        .progressViewStyle(.circular)
                        .tint(brandRed)
                        .frame(width: 18, height: 18)
                }
            } minimal: {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.circular)
                    .tint(brandRed)
            }
            .widgetURL(URL(string: "knightmusic://downloads"))
            .keylineTint(brandRed)
        }
    }
}

private struct TransferGlyph: View {
    let state: TransferActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(brandRed.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, state.fraction))
                .stroke(brandRed, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: glyph)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(state.isFinished && state.failed > 0 ? .orange : brandRed)
        }
        .frame(width: size, height: size)
    }

    private var glyph: String {
        guard state.isFinished else { return "arrow.down" }
        return state.failed > 0 ? "exclamationmark" : "checkmark"
    }
}

private struct TransferLockScreenView: View {
    let state: TransferActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            TransferGlyph(state: state, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(state.headline)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("Duet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let title = state.currentTitle, !state.isFinished {
                    Text(state.currentArtist.map { "\(title) · \($0)" } ?? title)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                } else if state.isFinished {
                    Text(state.failed > 0 ? "Open Duet to retry the failed songs." : "Ready to play offline.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                ProgressView(value: state.fraction)
                    .tint(state.isFinished && state.failed > 0 ? .orange : brandRed)
            }
        }
    }
}
