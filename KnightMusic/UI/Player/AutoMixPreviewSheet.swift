import SwiftUI

/// Shows how AutoMix will blend the current song into the next one, from the server's analysis of both:
/// loudness of A's outro and B's intro on one timeline, the volume curves, the overlap and the bass swap,
/// tempos/keys/stretch — and plays the real transition on demand.
struct AutoMixPreviewSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryRepository.self) private var library

    @State private var shown: PlannedMix?
    @State private var summaryA: AutoMixTrackSummary?
    @State private var summaryB: AutoMixTrackSummary?
    @State private var isPreviewing = false
    @State private var matches: [Song] = []
    @State private var matchesFor: String?
    @State private var isLoadingShowcase = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !settings.autoMixEnabled {
                        disabledState
                    } else if let mix = shown {
                        pairHeader(mix)
                        timelineCard(mix)
                        statsGrid(mix)
                        explanation(mix)
                        matchesSection
                        showcaseButton
                    } else {
                        emptyState
                        showcaseButton
                    }
                }
                .padding(.horizontal, Theme.margin + 4)
                .padding(.vertical, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle("AutoMix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle("AutoMix", isOn: Binding(get: { settings.autoMixEnabled },
                                                    set: { settings.autoMixEnabled = $0 }))
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { adopt(player.plannedMix) }
        .onChange(of: player.plannedMix) { _, new in
            // While a preview plays, keep showing that transition even after the next one gets planned.
            if !isPreviewing || shown == nil { adopt(new) }
        }
        .task(id: shown?.from.id.appending(shown?.to.id ?? "")) {
            guard let mix = shown else { return }
            async let a = player.autoMixSummary(songId: mix.from.id)
            async let b = player.autoMixSummary(songId: mix.to.id)
            let (sa, sb) = await (a, b)
            withAnimation(.smooth) {
                summaryA = sa
                summaryB = sb
            }
        }
        .task(id: player.currentSong?.id) {
            if let id = player.currentSong?.id { await loadMatches(for: id) }
        }
    }

    // MARK: Beat-matched suggestions

    @ViewBuilder
    private var matchesSection: some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Blends beat-matched from here")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text("Tap one to play it next, then play the transition.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                ForEach(matches) { song in
                    Button {
                        Haptics.impact(.light)
                        isPreviewing = false
                        player.enqueue([song], next: true)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(coverArt: song.coverArt, pointSize: 44, cornerRadius: 6)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.label)
                                    .lineLimit(1)
                                Text(song.artist ?? "")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: shown?.to.id == song.id ? "checkmark.circle.fill" : "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var showcaseButton: some View {
        Button {
            Haptics.impact(.medium)
            Task { await playShowcase() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isLoadingShowcase ? "hourglass" : "music.note.list")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play the AutoMix Showcase")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Text("A playlist where every song blends beat-matched into the next, kept up to date as your library is analysed.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(isLoadingShowcase)
    }

    private func playShowcase() async {
        isLoadingShowcase = true
        defer { isLoadingShowcase = false }
        let ids = await player.autoMixShowcase()
        let songs = await library.songs(ids: ids)
        let byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byId[$0] }
        guard ordered.count >= 2 else { return }
        isPreviewing = false
        player.play(ordered, startAt: 0, shuffle: false)
    }

    private func loadMatches(for songId: String) async {
        guard matchesFor != songId else { return }
        matchesFor = songId
        let ids = await player.autoMixMatches(after: songId)
        let songs = await library.songs(ids: ids)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        withAnimation(.smooth) {
            matches = songs.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
    }

    private func adopt(_ mix: PlannedMix?) {
        guard let mix else { return }
        if mix != shown {
            shown = mix
            summaryA = nil
            summaryB = nil
        }
    }

    // MARK: Sections

    private func pairHeader(_ mix: PlannedMix) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            modeBadge(mix.plan.mode)
            HStack(spacing: 12) {
                songColumn(mix.from, summary: summaryA, role: "Now")
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.secondaryLabel)
                songColumn(mix.to, summary: summaryB, role: "Next")
            }
        }
    }

    private func modeBadge(_ mode: AutoMixPlan.Mode) -> some View {
        let (title, icon): (String, String) = switch mode {
        case .beatmatch: ("Beat-matched blend", "metronome.fill")
        case .crossfade: ("Smooth crossfade", "waveform.path")
        case .gapless: ("Gapless", "arrow.right.to.line")
        }
        return Label(title, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.accent.opacity(0.14), in: Capsule())
    }

    private func songColumn(_ song: Song, summary: AutoMixTrackSummary?, role: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(coverArt: song.coverArt, pointSize: 140, cornerRadius: 10, fillsContainer: true)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(role.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.tertiaryLabel)
                Text(song.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(song.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                chip(summary?.bpm.map { "\(Int($0.rounded())) BPM" } ?? "— BPM")
                chip(summary?.key?.camelot ?? "—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.label)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.label.opacity(0.08), in: Capsule())
    }

    private func timelineCard(_ mix: PlannedMix) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The transition")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.label)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !player.isPlaying)) { _ in
                AutoMixTimeline(mix: mix, summaryA: summaryA, summaryB: summaryB, playhead: playhead(for: mix))
                    .frame(height: 170)
            }
            HStack(spacing: 14) {
                legend(color: Theme.accent, text: mix.from.title)
                legend(color: .white, text: mix.to.title)
            }
        }
        .padding(16)
        .background(Theme.label.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
        }
    }

    private func statsGrid(_ mix: PlannedMix) -> some View {
        let a = mix.plan.a, b = mix.plan.b
        let overlap = ((a?.stop ?? 0) - (a?.start ?? 0)) / (a?.rate ?? 1)
        let stretchA = ((a?.rate ?? 1) - 1) * 100, stretchB = ((b?.rate ?? 1) - 1) * 100
        let startsAt = a.map { KMFormat.duration($0.start) } ?? "—"
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            stat("Blend starts", startsAt, detail: "into \(mix.from.title)")
            stat("Overlap", String(format: "%.1f s", max(overlap, 0)), detail: barsText(mix.plan))
            stat("Tempo now", String(format: "%+.1f%%", stretchA), detail: "pitch kept")
            stat("Tempo next", String(format: "%+.1f%%", stretchB), detail: "eases back after")
        }
    }

    private func barsText(_ plan: AutoMixPlan) -> String {
        if plan.mode == .beatmatch, let reason = plan.reason, let bars = reason.split(separator: ",").dropFirst().first {
            return bars.trimmingCharacters(in: .whitespaces)
        }
        return plan.mode == .crossfade ? "phrase-aligned" : "—"
    }

    private func stat(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryLabel)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.label)
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryLabel)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.label.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func explanation(_ mix: PlannedMix) -> some View {
        let lines: [(String, String)] = switch mix.plan.mode {
        case .beatmatch: [
            ("metronome", "Both songs are nudged to one tempo, so their beats land together. Pitch doesn\u{2019}t change."),
            ("music.note", "The next song starts on the first beat of a new phrase, with its bass held back."),
            ("arrow.left.arrow.right", "On the middle downbeat the basslines swap, then the current song fades out."),
            ("gauge.with.needle", "Afterwards the next song eases back to its own tempo."),
        ]
        case .crossfade: [
            ("waveform.path", "These tempos are too far apart to match beat for beat, so AutoMix crossfades on a phrase."),
            ("slider.horizontal.3", "The current song is softened with a sweeping filter while the next one rises."),
        ]
        case .gapless: [("arrow.right.to.line", "These tracks are meant to run into each other, so they play gapless.")]
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("How it sounds")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.label)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let (icon, text) = line
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(player.autoMixNote ?? "Play something with a song up next to see its transition.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var disabledState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.tertiaryLabel)
            Text("AutoMix is off")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.label)
            Text("Turn it on to blend songs into each other like a DJ, with beats matched and tempos eased together.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
            Button("Turn On AutoMix") { settings.autoMixEnabled = true }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    // MARK: Preview control

    private var previewState: PreviewState {
        guard let mix = shown else { return .unavailable }
        if player.currentSong?.id == mix.to.id { return .done }
        if player.currentSong?.id == mix.from.id, let a = mix.plan.a, player.currentTime >= a.start - 0.2 { return .mixing }
        return player.plannedMix == mix && player.canPreviewAutoMix ? .ready : .unavailable
    }

    private enum PreviewState { case ready, mixing, done, unavailable }

    @ViewBuilder
    private var bottomBar: some View {
        if settings.autoMixEnabled, shown != nil {
            Button {
                Haptics.impact(.medium)
                switch previewState {
                case .done:
                    isPreviewing = false
                    adopt(player.plannedMix)
                default:
                    isPreviewing = true
                    player.previewAutoMix()
                }
            } label: {
                Label(buttonTitle, systemImage: buttonIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(previewState == .mixing || (previewState == .unavailable && !isPreviewing))
            .padding(.horizontal, Theme.margin + 4)
            .padding(.bottom, 8)
        }
    }

    private var buttonTitle: String {
        switch previewState {
        case .ready: return "Play Transition"
        case .mixing: return "Mixing\u{2026}"
        case .done: return player.plannedMix != nil ? "Show Next Transition" : "Transition Played"
        case .unavailable: return "Preparing\u{2026}"
        }
    }

    private var buttonIcon: String {
        switch previewState {
        case .ready: return "play.fill"
        case .mixing: return "waveform"
        case .done: return "forward.fill"
        case .unavailable: return "hourglass"
        }
    }

    /// Seconds relative to the moment B comes in, on the real-time axis of the timeline.
    private func playhead(for mix: PlannedMix) -> Double? {
        guard let a = mix.plan.a, let b = mix.plan.b else { return nil }
        if player.currentSong?.id == mix.from.id {
            return (player.currentTime - a.start) / (a.rate ?? 1)
        }
        if player.currentSong?.id == mix.to.id {
            return (player.currentTime - b.start) / (b.rate ?? 1)
        }
        return nil
    }
}

/// Loudness of A's outro and B's intro on the real-time axis around the blend, shaped by the planned gains.
private struct AutoMixTimeline: View {
    let mix: PlannedMix
    let summaryA: AutoMixTrackSummary?
    let summaryB: AutoMixTrackSummary?
    let playhead: Double?

    private let before = 14.0, after = 14.0

    var body: some View {
        Canvas { context, size in
            guard let a = mix.plan.a, let b = mix.plan.b else { return }
            let rateA = a.rate ?? 1, rateB = b.rate ?? 1
            let overlap = ((a.stop ?? a.start) - a.start) / rateA
            let t0 = -before, t1 = overlap + after
            func x(_ t: Double) -> CGFloat { CGFloat((t - t0) / (t1 - t0)) * size.width }
            let base = size.height - 18

            // Overlap band
            let band = CGRect(x: x(0), y: 0, width: max(x(overlap) - x(0), 1), height: base)
            context.fill(Path(roundedRect: band, cornerRadius: 6), with: .color(.white.opacity(0.06)))

            // A: from `before` seconds ahead of the blend to its stop, real time -> A media time
            drawDeck(context: &context, size: size, base: base, x: x,
                     realRange: (t0, overlap), media: { a.start + $0 * rateA },
                     summary: summaryA, gain: a.gain, color: Theme.accent)
            // B: from its start to `after` seconds past the overlap
            drawDeck(context: &context, size: size, base: base, x: x,
                     realRange: (0, t1), media: { b.start + $0 * rateB },
                     summary: summaryB, gain: b.gain, color: .white)

            // Markers
            let handoff = ((a.handoff ?? a.start) - a.start) / rateA
            marker(context: &context, at: x(0), base: base, label: "Next in")
            if mix.plan.mode == .beatmatch {
                marker(context: &context, at: x(handoff), base: base, label: "Bass swap")
            }
            marker(context: &context, at: x(overlap), base: base, label: "Now out")

            if let playhead, playhead >= t0, playhead <= t1 {
                var line = Path()
                line.move(to: CGPoint(x: x(playhead), y: 0))
                line.addLine(to: CGPoint(x: x(playhead), y: base))
                context.stroke(line, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: x(playhead) - 5, y: -2, width: 10, height: 10)),
                             with: .color(Theme.accent))
            }
        }
        .accessibilityLabel("Transition timeline from \(mix.from.title) into \(mix.to.title)")
    }

    private func drawDeck(context: inout GraphicsContext, size: CGSize, base: CGFloat, x: (Double) -> CGFloat,
                          realRange: (Double, Double), media: (Double) -> Double,
                          summary: AutoMixTrackSummary?, gain: [[Double]], color: Color) {
        let steps = 140
        var top: [CGPoint] = []
        let ref = summary?.refDb ?? -8
        for k in 0...steps {
            let real = realRange.0 + (realRange.1 - realRange.0) * Double(k) / Double(steps)
            let m = media(real)
            let loudness = summary.map { level(in: $0, at: m, ref: ref) } ?? 0.6
            let g = value(of: gain, at: m)
            top.append(CGPoint(x: x(real), y: base - CGFloat(loudness * g) * (base - 8)))
        }
        guard let first = top.first, let last = top.last else { return }
        var area = Path()
        area.move(to: CGPoint(x: first.x, y: base))
        top.forEach { area.addLine(to: $0) }
        area.addLine(to: CGPoint(x: last.x, y: base))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.55), color.opacity(0.08)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: base)))
        var outline = Path()
        outline.addLines(top)
        context.stroke(outline, with: .color(color.opacity(0.9)), lineWidth: 1.5)
    }

    private func marker(context: inout GraphicsContext, at px: CGFloat, base: CGFloat, label: String) {
        var line = Path()
        line.move(to: CGPoint(x: px, y: 4))
        line.addLine(to: CGPoint(x: px, y: base))
        context.stroke(line, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        context.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7)),
                     at: CGPoint(x: px, y: base + 10))
    }

    /// 0…1 loudness of the bar playing at media time `t` (silence ≈ 30 dB below the song's loud level).
    private func level(in summary: AutoMixTrackSummary, at t: Double, ref: Double) -> Double {
        guard t >= 0, t <= summary.duration else { return 0 }
        let bar = summary.bars.last(where: { $0.t <= t }) ?? summary.bars.first
        guard let db = bar?.db else { return 0.6 }
        return min(max((db - (ref - 30)) / 30, 0.03), 1)
    }

    private func value(of frames: [[Double]], at t: Double) -> Double {
        let valid = frames.filter { $0.count >= 2 }
        guard let first = valid.first, let last = valid.last else { return 1 }
        if t <= first[0] { return first[1] }
        if t >= last[0] { return last[1] }
        for (lo, hi) in zip(valid, valid.dropFirst()) where t >= lo[0] && t <= hi[0] {
            let u = (t - lo[0]) / max(hi[0] - lo[0], 1e-9)
            return lo[1] + (hi[1] - lo[1]) * u
        }
        return last[1]
    }
}
