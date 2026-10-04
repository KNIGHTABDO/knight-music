import SwiftUI
import UIKit

/// Design tokens. Adaptive: pure black canvas + white text in dark mode (default, Arpeggi look), white canvas +
/// black text in light mode (Settings → Customize → Appearance). Arpeggi-red accent (asset `AccentColor`, or a stored hex).
/// The full-screen player is always forced dark (it sits on artwork / palette backgrounds).
enum Theme {
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .systemBackground })
    /// Grouped-list canvas (light: #F2F2F7, dark: pure black).
    static let groupedBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .systemGroupedBackground })
    static let secondaryBackground = Color(uiColor: .systemGray6)
    static let label = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08) })

    /// User-changeable later (Settings → Customize) via UserDefaults "accentHex"; defaults to the asset color.
    static var accent: Color {
        if let hex = UserDefaults.standard.string(forKey: "accentHex"), let c = Color(hex: hex) { return c }
        return Color("AccentColor")
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let tile: CGFloat = 8
        static let card: CGFloat = 14
        static let large: CGFloat = 22
        static let hero: CGFloat = 28
    }

    /// Standard horizontal page margin.
    static let margin: CGFloat = 16
}

extension Font {
    static let kmLargeTitle = Font.system(size: 34, weight: .bold)
    static let kmSectionTitle = Font.system(size: 22, weight: .bold)
    static let kmTileTitle = Font.system(size: 15)
    static let kmTileSubtitle = Font.system(size: 13)
    static let kmRowTitle = Font.system(size: 17)
    static let kmRowSubtitle = Font.system(size: 15)
    static let kmPlayerTitle = Font.system(size: 20, weight: .semibold)
}

extension Color {
    /// "#FA2D48" / "FA2D48"
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

/// Display strings used across lists.
enum KMFormat {
    /// 235 -> "3:55", 3725 -> "1:02:05"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 12180 -> "3 hrs, 23 min", 3900 -> "1 hr, 5 min", 600 -> "10 min"
    static func totalDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return "\(h) \(h == 1 ? "hr" : "hrs"), \(m) min"
    }

    /// 67 -> "67 Songs", 1 -> "1 Song"
    static func songCount(_ n: Int) -> String { "\(n) \(n == 1 ? "Song" : "Songs")" }
    static func albumCount(_ n: Int) -> String { "\(n) \(n == 1 ? "Album" : "Albums")" }

    /// "67 Songs • 3 hrs, 23 min"
    static func songsAndDuration(count: Int, seconds: TimeInterval) -> String {
        "\(songCount(count)) • \(totalDuration(seconds))"
    }
}
