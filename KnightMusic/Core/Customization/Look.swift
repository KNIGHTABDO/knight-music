import SwiftUI

/// A complete visual style for the app: colors, type, player, lyrics, library and Home layout.
/// Saved looks are stored as JSON and can be exported/imported as `.knightlook` files.
/// Decoding is tolerant: a field missing from an older or hand-edited file falls back to the default.
struct Look: Codable, Equatable, Identifiable, Sendable {
    enum AccentSource: String, Codable, CaseIterable, Identifiable, Sendable {
        case fixed, artwork
        var id: String { rawValue }
        var title: String { self == .fixed ? "Fixed" : "From Artwork" }
    }

    enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var systemImage: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max.fill"
            case .dark: "moon.fill"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Typeface: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, rounded, serif, monospaced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "Default"
            case .rounded: "Rounded"
            case .serif: "Serif"
            case .monospaced: "Mono"
            }
        }
        var design: Font.Design {
            switch self {
            case .standard: .default
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            }
        }
    }

    enum TypeWidth: String, Codable, CaseIterable, Identifiable, Sendable {
        case condensed, standard, expanded
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var width: Font.Width {
            switch self {
            case .condensed: .condensed
            case .standard: .standard
            case .expanded: .expanded
            }
        }
    }

    enum Backdrop: String, Codable, CaseIterable, Identifiable, Sendable {
        case palette, aurora, blurredArtwork, spotlight, black
        var id: String { rawValue }
        var title: String {
            switch self {
            case .palette: "Flowing Colors"
            case .aurora: "Aurora"
            case .blurredArtwork: "Blurred Cover"
            case .spotlight: "Spotlight"
            case .black: "Pure Black"
            }
        }
        var systemImage: String {
            switch self {
            case .palette: "drop.halffull"
            case .aurora: "sparkles"
            case .blurredArtwork: "photo.fill"
            case .spotlight: "light.overhead.right.fill"
            case .black: "circle.fill"
            }
        }
    }

    enum ArtworkShape: String, Codable, CaseIterable, Identifiable, Sendable {
        case card, vinyl, circle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .card: "Card"
            case .vinyl: "Vinyl"
            case .circle: "Circle"
            }
        }
        var systemImage: String {
            switch self {
            case .card: "square.fill"
            case .vinyl: "record.circle"
            case .circle: "circle.fill"
            }
        }
    }

    enum Pulse: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, beat, breathe
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .beat: "To the Beat"
            case .breathe: "Breathe"
            }
        }
    }

    enum LyricsHighlight: String, Codable, CaseIterable, Identifiable, Sendable {
        case white, accent, artwork
        var id: String { rawValue }
        var title: String {
            switch self {
            case .white: "White"
            case .accent: "Accent"
            case .artwork: "Artwork"
            }
        }
    }

    enum LyricsAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
        case leading, center
        var id: String { rawValue }
        var title: String { self == .leading ? "Left" : "Center" }
    }

    enum GridDensity: String, Codable, CaseIterable, Identifiable, Sendable {
        case compact, comfortable, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// Minimum tile width (iPhone, iPad).
        var minimum: (compact: CGFloat, regular: CGFloat) {
            switch self {
            case .compact: (104, 140)
            case .comfortable: (160, 190)
            case .large: (300, 260)
            }
        }
    }

    enum ArtistShape: String, Codable, CaseIterable, Identifiable, Sendable {
        case circle, rounded
        var id: String { rawValue }
        var title: String { self == .circle ? "Circle" : "Rounded" }
    }

    var id: UUID
    var name: String
    var symbol: String

    // Colors & type
    var accentHex: String
    var accentSource: AccentSource
    var appearance: Appearance
    var typeface: Typeface
    var typeWidth: TypeWidth

    // Player
    var backdrop: Backdrop
    var artworkShape: ArtworkShape
    var artworkRadius: Double
    var artworkGlow: Bool
    var pulse: Pulse
    var shrinkWhenPaused: Bool
    var showRatings: Bool
    var showVolume: Bool

    // Lyrics
    var lyricsScale: Double
    var lyricsAlignment: LyricsAlignment
    var lyricsHighlight: LyricsHighlight
    var lyricsBlur: Bool
    var lyricsGlow: Bool

    // Library
    var tileRadius: Double
    var gridDensity: GridDensity
    var artistShape: ArtistShape

    static let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static let knightRed = Look(
        id: defaultId, name: "Knight Red", symbol: "shield.lefthalf.filled",
        accentHex: "#FA2D48", accentSource: .fixed, appearance: .dark, typeface: .standard, typeWidth: .standard,
        backdrop: .palette, artworkShape: .card, artworkRadius: 12, artworkGlow: false, pulse: .off,
        shrinkWhenPaused: true, showRatings: true, showVolume: true,
        lyricsScale: 1, lyricsAlignment: .leading, lyricsHighlight: .white, lyricsBlur: true, lyricsGlow: true,
        tileRadius: 8, gridDensity: .comfortable, artistShape: .circle
    )

    var accentColor: Color { Color(hex: accentHex) ?? Color(red: 0.98, green: 0.176, blue: 0.282) }

    /// A copy with a fresh id and name, for "Save as new look".
    func copy(named newName: String) -> Look {
        var look = self
        look.id = UUID()
        look.name = newName
        return look
    }

    /// Pretty JSON for sharing as a `.knightlook` file.
    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// True when both looks would render the same (ignores id, name and symbol).
    func rendersSame(as other: Look) -> Bool {
        var a = self, b = other
        a.id = b.id; a.name = b.name; a.symbol = b.symbol
        return a == b
    }
}

extension Look {
    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, accentHex, accentSource, appearance, typeface, typeWidth
        case backdrop, artworkShape, artworkRadius, artworkGlow, pulse, shrinkWhenPaused, showRatings, showVolume
        case lyricsScale, lyricsAlignment, lyricsHighlight, lyricsBlur, lyricsGlow
        case tileRadius, gridDensity, artistShape
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Look.knightRed
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        id = v(.id, UUID())
        name = v(.name, "Imported Look")
        symbol = v(.symbol, "paintpalette.fill")
        let hex = v(.accentHex, d.accentHex)
        accentHex = Color(hex: hex) == nil ? d.accentHex : hex
        accentSource = v(.accentSource, d.accentSource)
        appearance = v(.appearance, d.appearance)
        typeface = v(.typeface, d.typeface)
        typeWidth = v(.typeWidth, d.typeWidth)
        backdrop = v(.backdrop, d.backdrop)
        artworkShape = v(.artworkShape, d.artworkShape)
        artworkRadius = min(max(v(.artworkRadius, d.artworkRadius), 0), 40)
        artworkGlow = v(.artworkGlow, d.artworkGlow)
        pulse = v(.pulse, d.pulse)
        shrinkWhenPaused = v(.shrinkWhenPaused, d.shrinkWhenPaused)
        showRatings = v(.showRatings, d.showRatings)
        showVolume = v(.showVolume, d.showVolume)
        lyricsScale = min(max(v(.lyricsScale, d.lyricsScale), 0.7), 1.5)
        lyricsAlignment = v(.lyricsAlignment, d.lyricsAlignment)
        lyricsHighlight = v(.lyricsHighlight, d.lyricsHighlight)
        lyricsBlur = v(.lyricsBlur, d.lyricsBlur)
        lyricsGlow = v(.lyricsGlow, d.lyricsGlow)
        tileRadius = min(max(v(.tileRadius, d.tileRadius), 0), 30)
        gridDensity = v(.gridDensity, d.gridDensity)
        artistShape = v(.artistShape, d.artistShape)
    }
}

extension Look {
    /// Ready-made looks shown first in the gallery. Fixed ids so "selected" survives relaunches.
    static let builtIns: [Look] = {
        func make(_ n: Int, _ name: String, _ symbol: String, _ edit: (inout Look) -> Void) -> Look {
            var look = knightRed
            look.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
            look.name = name
            look.symbol = symbol
            edit(&look)
            return look
        }
        return [
            knightRed,
            make(2, "Neon Night", "bolt.fill") {
                $0.accentHex = "#00E5FF"; $0.backdrop = .aurora; $0.artworkGlow = true; $0.pulse = .beat
                $0.typeface = .rounded; $0.lyricsHighlight = .accent; $0.artworkRadius = 20; $0.tileRadius = 14
            },
            make(3, "Vinyl Lounge", "record.circle") {
                $0.accentHex = "#E8A33D"; $0.artworkShape = .vinyl; $0.backdrop = .spotlight; $0.typeface = .serif
                $0.lyricsAlignment = .center; $0.lyricsHighlight = .accent; $0.shrinkWhenPaused = false
            },
            make(4, "Zellige", "seal.fill") {
                $0.accentHex = "#1FA187"; $0.backdrop = .palette; $0.artworkRadius = 28; $0.tileRadius = 18
                $0.artistShape = .rounded; $0.typeface = .rounded; $0.artworkGlow = true
            },
            make(5, "Gold Raï", "sun.max.fill") {
                $0.accentHex = "#D4AF37"; $0.backdrop = .blurredArtwork; $0.typeface = .serif; $0.typeWidth = .expanded
                $0.lyricsScale = 1.15; $0.lyricsHighlight = .accent; $0.pulse = .breathe
            },
            make(6, "Chameleon", "paintpalette.fill") {
                $0.accentSource = .artwork; $0.backdrop = .palette; $0.lyricsHighlight = .artwork; $0.artworkGlow = true
                $0.pulse = .beat; $0.artworkRadius = 16
            },
            make(7, "Mono", "circle.lefthalf.filled") {
                $0.accentHex = "#E5E5EA"; $0.backdrop = .black; $0.typeface = .monospaced; $0.typeWidth = .condensed
                $0.artworkRadius = 0; $0.tileRadius = 0; $0.artistShape = .rounded; $0.lyricsBlur = false; $0.lyricsGlow = false
            },
            make(8, "Big & Bold", "textformat.size") {
                $0.accentHex = "#FF375F"; $0.gridDensity = .large; $0.lyricsScale = 1.35; $0.typeWidth = .expanded
                $0.artworkShape = .circle; $0.backdrop = .aurora
            },
            make(9, "Daylight", "sun.horizon.fill") {
                $0.accentHex = "#007AFF"; $0.appearance = .light; $0.gridDensity = .compact; $0.tileRadius = 12
                $0.backdrop = .blurredArtwork; $0.typeface = .rounded
            }
        ]
    }()
}
