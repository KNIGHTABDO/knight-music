import SwiftUI
import UIKit

/// One home-screen icon. Alternates are `Icon-*` app icon sets in the asset catalog (listed in
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`); the gallery shows the matching `IconPreview-*` image.
struct AppIconChoice: Identifiable, Hashable, Sendable {
    enum Unlock: Hashable, Sendable {
        /// Hours of listening (all time, from Replay).
        case hours(Int)
        /// Hidden until found in the icon gallery.
        case secret
    }

    let id: String
    let name: String
    let caption: String
    var unlock: Unlock?

    static let primaryId = "AppIcon"

    /// Value for `setAlternateIconName` (nil = primary icon).
    var alternateName: String? { id == Self.primaryId ? nil : id }
    var previewImage: String { "IconPreview-\(id)" }

    static let all: [AppIconChoice] = [
        AppIconChoice(id: primaryId, name: "Knight Red", caption: "The original glass knight"),
        AppIconChoice(id: "Icon-Neon", name: "Neon Night", caption: "Cyan and magenta tubes"),
        AppIconChoice(id: "Icon-Zellige", name: "Zellige", caption: "Hand-cut Moroccan tiles"),
        AppIconChoice(id: "Icon-Vinyl", name: "Vinyl", caption: "Pressed at 33⅓"),
        AppIconChoice(id: "Icon-Emerald", name: "Gold Raï", caption: "Gold leaf on emerald"),
        AppIconChoice(id: "Icon-Chrome", name: "Liquid Chrome", caption: "Polished mirror metal"),
        AppIconChoice(id: "Icon-Synthwave", name: "Synthwave", caption: "1986 sunset grid"),
        AppIconChoice(id: "Icon-Sahara", name: "Sahara", caption: "Dunes under the moon"),
        AppIconChoice(id: "Icon-Pixel", name: "Pixel Knight", caption: "8-bit hero"),
        AppIconChoice(id: "Icon-Origami", name: "Origami", caption: "One folded sheet"),
        AppIconChoice(id: "Icon-Cassette", name: "Mixtape", caption: "Side A, track 1"),
        AppIconChoice(id: "Icon-Golden", name: "Golden Record", caption: "For 100 hours of music", unlock: .hours(100)),
        AppIconChoice(id: "Icon-Phantom", name: "Phantom", caption: "You found it", unlock: .secret)
    ]
}

/// Switches the home-screen icon and remembers found secrets.
@MainActor @Observable
final class AppIconManager {
    static let shared = AppIconManager()

    private(set) var currentId: String = UIApplication.shared.alternateIconName ?? AppIconChoice.primaryId
    var secretFound: Bool = UserDefaults.standard.bool(forKey: "icon.secretFound") {
        didSet { UserDefaults.standard.set(secretFound, forKey: "icon.secretFound") }
    }

    var supportsAlternates: Bool { UIApplication.shared.supportsAlternateIcons }

    func isUnlocked(_ icon: AppIconChoice, listenedHours: Int) -> Bool {
        switch icon.unlock {
        case nil: true
        case .hours(let needed): listenedHours >= needed
        case .secret: secretFound
        }
    }

    func setIcon(_ icon: AppIconChoice) async throws {
        guard icon.id != currentId else { return }
        try await UIApplication.shared.setAlternateIconName(icon.alternateName)
        currentId = icon.id
    }
}
