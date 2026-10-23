import SwiftUI

/// Apple Music-style "Lossless" / "Hi-Res Lossless" classification from the file's metadata.
enum AudioQualityBadge: Equatable {
    case lossless
    case hiResLossless

    private static let losslessSuffixes: Set<String> = ["flac", "alac", "wav", "aif", "aiff", "ape", "wv", "dsf", "dff", "tta"]

    init?(song: Song) {
        let suffix = (song.suffix ?? "").lowercased()
        let type = (song.contentType ?? "").lowercased()
        let depth = song.bitDepth ?? 0
        // m4a can hold AAC or ALAC; only ALAC reports a bit depth.
        let isLossless = Self.losslessSuffixes.contains(suffix)
            || type.contains("flac") || type.contains("alac") || type.contains("wav")
            || (suffix == "m4a" && depth > 0)
        guard isLossless else { return nil }
        self = depth > 16 || (song.samplingRate ?? 0) > 48_000 ? .hiResLossless : .lossless
    }

    /// The album's badge is the best one any of its songs has.
    init?(songs: [Song]) {
        let badges = songs.compactMap(AudioQualityBadge.init(song:))
        guard !badges.isEmpty else { return nil }
        self = badges.contains(.hiResLossless) ? .hiResLossless : .lossless
    }

    var title: String { self == .hiResLossless ? "Hi-Res Lossless" : "Lossless" }
}

struct QualityBadge: View {
    let badge: AudioQualityBadge
    var color: Color = Theme.secondaryLabel

    var body: some View {
        Label(badge.title, systemImage: "waveform")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
            .accessibilityLabel(badge.title)
    }
}

enum AudioFormatText {
    static func sampleRate(_ hz: Int?) -> String? {
        guard let hz, hz > 0 else { return nil }
        let khz = Double(hz) / 1000
        return khz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    static func bitRate(_ kbps: Int?) -> String? {
        guard let kbps, kbps > 0 else { return nil }
        return "\(kbps) kbps"
    }

    static func size(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func gain(_ db: Double?) -> String? {
        db.map { String(format: "%+.2f dB", $0) }
    }
}
