import SwiftUI
import UIKit

/// 2–4 vibrant colors pulled from a cover, tuned so white text stays legible on top of them.
struct ArtworkPalette: Sendable, Equatable {
    var colors: [UIColor]

    static let fallback = ArtworkPalette(colors: [
        UIColor(hue: 0.62, saturation: 0.25, brightness: 0.30, alpha: 1),
        UIColor(hue: 0.60, saturation: 0.20, brightness: 0.16, alpha: 1)
    ])

    var swiftUIColors: [Color] { colors.map { Color($0) } }
    var primary: Color { Color(colors.first ?? .darkGray) }

    /// Full-screen player background: palette colors fading into near-black at the bottom.
    var backgroundGradient: LinearGradient {
        LinearGradient(colors: swiftUIColors + [Color.black.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Cache + async entry point

    private static let cache = PaletteCache()

    /// Palette for a cover, cached per coverArt id. Decoding and clustering run off the main thread.
    static func palette(for coverArt: String?) async -> ArtworkPalette {
        guard let id = coverArt, !id.isEmpty else { return .fallback }
        if let hit = await cache.get(id) { return hit }
        guard let image = await ArtworkLoader.shared.image(coverArt: id, size: 120) else { return .fallback }
        let result = await Task.detached(priority: .utility) { ArtworkPalette.extract(from: image) }.value
        await cache.put(result, for: id)
        return result
    }

    // MARK: Extraction (k-means over a 40x40 downsample)

    static func extract(from image: UIImage) -> ArtworkPalette {
        guard let pixels = downsample(image, side: 40), !pixels.isEmpty else { return .fallback }
        let k = 6
        let sorted = pixels.sorted { $0.luma < $1.luma }
        var centers: [RGB] = (0..<k).map { sorted[min(sorted.count - 1, ($0 * 2 + 1) * sorted.count / (k * 2))] }
        var assign = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<8 {
            for (i, p) in pixels.enumerated() {
                var best = 0
                var bestD = Double.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = p.distance(to: center)
                    if d < bestD { bestD = d; best = c }
                }
                assign[i] = best
            }
            var sums = [[Double]](repeating: [0, 0, 0, 0], count: k)
            for (i, p) in pixels.enumerated() {
                let c = assign[i]
                sums[c][0] += p.r; sums[c][1] += p.g; sums[c][2] += p.b; sums[c][3] += 1
            }
            for c in 0..<k where sums[c][3] > 0 {
                centers[c] = RGB(r: sums[c][0] / sums[c][3], g: sums[c][1] / sums[c][3], b: sums[c][2] / sums[c][3])
            }
        }
        var counts = [Double](repeating: 0, count: k)
        for a in assign { counts[a] += 1 }

        struct Candidate { var color: UIColor; var hue: CGFloat; var score: Double }
        var candidates: [Candidate] = []
        for c in 0..<k where counts[c] > 0 {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            UIColor(red: centers[c].r, green: centers[c].g, blue: centers[c].b, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            let share = counts[c] / Double(pixels.count)
            let midLuma = 1 - abs(Double(b) - 0.55) * 1.4
            let score = (0.15 + share) * (0.25 + Double(s)) * max(0.1, midLuma)
            candidates.append(Candidate(color: legible(h: h, s: s, b: b), hue: h, score: score))
        }
        candidates.sort { $0.score > $1.score }

        var picked: [Candidate] = []
        for cand in candidates {
            let distinct = picked.allSatisfy {
                hueDistance($0.hue, cand.hue) > 0.06 || abs(brightness($0.color) - brightness(cand.color)) > 0.2
            }
            if distinct { picked.append(cand) }
            if picked.count == 4 { break }
        }
        if picked.count < 2, let first = picked.first {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            first.color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            picked.append(Candidate(color: UIColor(hue: h, saturation: s, brightness: max(0.14, b * 0.45), alpha: 1), hue: h, score: 0))
        }
        guard !picked.isEmpty else { return .fallback }
        let ordered = picked.map(\.color).sorted { brightness($0) > brightness($1) }
        return ArtworkPalette(colors: ordered)
    }

    /// Keeps hue, lifts dull colors and pulls bright ones down so white text reads on any of them.
    private static func legible(h: CGFloat, s: CGFloat, b: CGFloat) -> UIColor {
        let sat = s < 0.12 ? s : max(s, 0.35)
        return UIColor(hue: h, saturation: min(1, sat), brightness: min(0.62, max(0.22, b)), alpha: 1)
    }

    private static func brightness(_ c: UIColor) -> CGFloat {
        var b: CGFloat = 0
        c.getHue(nil, saturation: nil, brightness: &b, alpha: nil)
        return b
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    private struct RGB {
        var r: Double, g: Double, b: Double
        var luma: Double { 0.299 * r + 0.587 * g + 0.114 * b }
        func distance(to o: RGB) -> Double {
            let dr = r - o.r, dg = g - o.g, db = b - o.b
            return dr * dr + dg * dg + db * db
        }
    }

    private static func downsample(_ image: UIImage, side: Int) -> [RGB]? {
        guard let cg = image.cgImage else { return nil }
        var raw = [UInt8](repeating: 0, count: side * side * 4)
        let drew = raw.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        return (0..<(side * side)).map {
            RGB(r: Double(raw[$0 * 4]) / 255, g: Double(raw[$0 * 4 + 1]) / 255, b: Double(raw[$0 * 4 + 2]) / 255)
        }
    }
}

private actor PaletteCache {
    private var entries: [String: ArtworkPalette] = [:]
    func get(_ id: String) -> ArtworkPalette? { entries[id] }
    func put(_ palette: ArtworkPalette, for id: String) { entries[id] = palette }
}
