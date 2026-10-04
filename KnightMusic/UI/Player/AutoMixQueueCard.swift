import SwiftUI

/// "Up next" AutoMix summary under the queue toggles; opens the transition preview.
struct AutoMixQueueCard: View {
    @Environment(PlayerEngine.self) private var player
    let open: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            open()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: player.isAutoMixing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Preview")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHint("Shows how AutoMix will blend into the next song")
    }

    private var icon: String {
        switch player.plannedMix?.plan.mode {
        case .beatmatch: return "metronome.fill"
        case .crossfade: return "waveform.path"
        case .gapless, .none: return "waveform.path"
        }
    }

    private var title: String {
        if player.isAutoMixing { return "Mixing into the next song" }
        guard let mix = player.plannedMix else { return "AutoMix" }
        switch mix.plan.mode {
        case .beatmatch: return "Beat-matched into \(mix.to.title)"
        case .crossfade: return "Crossfade into \(mix.to.title)"
        case .gapless: return "Gapless into \(mix.to.title)"
        }
    }

    private var subtitle: String {
        if let mix = player.plannedMix {
            if mix.plan.mode == .beatmatch, let reason = mix.plan.reason, let bpm = reason.split(separator: ",").first {
                return String(bpm)
            }
            return player.autoMixNote ?? "Phrase-aligned blend"
        }
        return player.autoMixNote ?? "Planning the next transition\u{2026}"
    }
}
