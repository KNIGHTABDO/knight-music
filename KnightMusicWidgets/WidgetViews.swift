import SwiftUI
import WidgetKit

// MARK: - Color extensions

extension Color {
    init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xff, (int >> 8) & 0xff, int & 0xff)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xff, (int >> 16) & 0xff, (int >> 8) & 0xff, int & 0xff)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Arpeggi red #FA2D48
    static let kmRed = Color(red: 250 / 255, green: 45 / 255, blue: 72 / 255)
}

// MARK: - Format duration

func formatDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
}

// MARK: - Artwork Image

struct ArtworkImage: View {
    let filename: String?

    var body: some View {
        if let filename,
           let url = WidgetSnapshot.artworkFileURL(for: filename),
           let uiImage = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}

// MARK: - Widget Background

struct WidgetBackground: View {
    let hex: String?

    var body: some View {
        if let hex, !hex.isEmpty {
            let base = Color(hex: hex)
            LinearGradient(
                colors: [
                    base.opacity(0.40),
                    Color(red: 0.05, green: 0.05, blue: 0.07),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.12, blue: 0.14),
                    Color(red: 0.04, green: 0.04, blue: 0.05),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
