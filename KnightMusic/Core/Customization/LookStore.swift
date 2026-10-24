import SwiftUI
import UIKit

/// Owns the active `Look`, the user's saved looks and the customization preferences that aren't part of a look
/// (start tab, Home layout, haptics, shake, day/night schedule). Everything is persisted in UserDefaults.
/// `shared` exists for design tokens (`Theme.accent`) and `Haptics`, which have no environment.
@MainActor @Observable
final class LookStore {
    static let shared = LookStore()

    /// The look being shown. Edits apply live and persist immediately.
    var current: Look { didSet { persist(current, Keys.current) } }
    /// User-saved looks (the built-ins are `Look.builtIns`).
    private(set) var saved: [Look] { didSet { persist(saved, Keys.saved) } }

    var startTab: StartTab { didSet { save(startTab.rawValue, Keys.startTab) } }
    var homeOrder: [HomeSection] { didSet { persist(homeOrder, Keys.homeOrder) } }
    var hiddenHomeSections: Set<HomeSection> { didSet { persist(Array(hiddenHomeSections), Keys.hiddenHome) } }
    var homeGreeting: Bool { didSet { save(homeGreeting, Keys.greeting) } }
    var haptics: HapticsLevel { didSet { save(haptics.rawValue, Keys.haptics) } }
    var shakeAction: ShakeAction { didSet { save(shakeAction.rawValue, Keys.shake) } }

    var scheduleEnabled: Bool { didSet { save(scheduleEnabled, Keys.scheduleOn); lastScheduledPeriod = nil; applyScheduleIfNeeded() } }
    var dayLookId: UUID { didSet { save(dayLookId.uuidString, Keys.dayLook); lastScheduledPeriod = nil; applyScheduleIfNeeded() } }
    var nightLookId: UUID { didSet { save(nightLookId.uuidString, Keys.nightLook); lastScheduledPeriod = nil; applyScheduleIfNeeded() } }
    /// Hours (0–23) at which the day and the night look start.
    var dayStartHour: Int { didSet { save(dayStartHour, Keys.dayHour); lastScheduledPeriod = nil; applyScheduleIfNeeded() } }
    var nightStartHour: Int { didSet { save(nightStartHour, Keys.nightHour); lastScheduledPeriod = nil; applyScheduleIfNeeded() } }

    /// Vivid color taken from the playing song's cover (used when the look's accent source is `.artwork`).
    private(set) var artworkAccent: Color?
    /// The playing song's palette, for lyrics highlighted "from artwork".
    private(set) var artworkColors: [Color] = []
    private var lastArtworkAccentHex: String?
    private var lastScheduledPeriod: Bool?

    private enum Keys {
        static let current = "look.current", saved = "look.saved", startTab = "look.startTab"
        static let homeOrder = "look.homeOrder", hiddenHome = "look.hiddenHome", greeting = "look.greeting"
        static let haptics = "look.haptics", shake = "look.shake"
        static let scheduleOn = "look.schedule", dayLook = "look.dayLook", nightLook = "look.nightLook"
        static let dayHour = "look.dayHour", nightHour = "look.nightHour"
    }

    private init() {
        let d = UserDefaults.standard
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            guard let data = d.data(forKey: key) else { return nil }
            do { return try decoder.decode(T.self, from: data) } catch {
                Log.app.error("Couldn't read \(key): \(error)")
                return nil
            }
        }

        if let stored = decode(Look.self, Keys.current) {
            current = stored
        } else {
            // First launch with looks: carry over the old accent / appearance / ratings settings.
            var look = Look.knightRed
            if let hex = d.string(forKey: "accentColorHex"), Color(hex: hex) != nil { look.accentHex = hex }
            if let raw = d.string(forKey: "appearance"), let appearance = Look.Appearance(rawValue: raw) { look.appearance = appearance }
            if let ratings = d.object(forKey: "showRatings") as? Bool { look.showRatings = ratings }
            current = look
        }
        saved = decode([Look].self, Keys.saved) ?? []
        startTab = StartTab(rawValue: d.string(forKey: Keys.startTab) ?? "") ?? .home
        homeOrder = HomeSection.normalized(decode([HomeSection].self, Keys.homeOrder) ?? HomeSection.allCases)
        hiddenHomeSections = Set(decode([HomeSection].self, Keys.hiddenHome) ?? [])
        homeGreeting = d.object(forKey: Keys.greeting) as? Bool ?? true
        haptics = HapticsLevel(rawValue: d.string(forKey: Keys.haptics) ?? "") ?? .normal
        shakeAction = ShakeAction(rawValue: d.string(forKey: Keys.shake) ?? "") ?? .off
        scheduleEnabled = d.bool(forKey: Keys.scheduleOn)
        dayLookId = d.string(forKey: Keys.dayLook).flatMap(UUID.init(uuidString:)) ?? Look.builtIns[8].id
        nightLookId = d.string(forKey: Keys.nightLook).flatMap(UUID.init(uuidString:)) ?? Look.defaultId
        dayStartHour = d.object(forKey: Keys.dayHour) as? Int ?? 7
        nightStartHour = d.object(forKey: Keys.nightHour) as? Int ?? 19
    }

    // MARK: - Derived

    var accent: Color {
        current.accentSource == .artwork ? (artworkAccent ?? current.accentColor) : current.accentColor
    }

    /// Color of the lyric line being sung.
    var lyricsHighlight: Color {
        switch current.lyricsHighlight {
        case .white: .white
        case .accent: accent
        case .artwork: artworkColors.first.map { $0.mix(with: .white, by: 0.35) } ?? .white
        }
    }

    var allLooks: [Look] { Look.builtIns + saved }

    func look(id: UUID) -> Look? { allLooks.first { $0.id == id } }

    var isBuiltIn: Bool { Look.builtIns.contains { $0.id == current.id } }
    var isSaved: Bool { saved.contains { $0.id == current.id } }

    /// The current look differs from the stored version it was picked from.
    var hasUnsavedChanges: Bool {
        guard let base = look(id: current.id) else { return true }
        return !base.rendersSame(as: current)
    }

    func isActive(_ look: Look) -> Bool { look.id == current.id }

    // MARK: - Applying & saving

    func apply(_ look: Look) {
        withAnimation(.smooth(duration: 0.45)) { current = look }
        Haptics.selection()
    }

    /// Writes the current edits back into the saved look they came from.
    func saveChanges() {
        guard let index = saved.firstIndex(where: { $0.id == current.id }) else { return }
        saved[index] = current
        Haptics.success()
    }

    @discardableResult
    func saveAsNew(named name: String) -> Look {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let look = current.copy(named: trimmed.isEmpty ? "My Look \(saved.count + 1)" : trimmed)
        saved.append(look)
        current = look
        Haptics.success()
        return look
    }

    func rename(_ look: Look, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = saved.firstIndex(where: { $0.id == look.id }) else { return }
        saved[index].name = trimmed
        if current.id == look.id { current.name = trimmed }
    }

    func setSymbol(_ symbol: String, for look: Look) {
        guard let index = saved.firstIndex(where: { $0.id == look.id }) else { return }
        saved[index].symbol = symbol
        if current.id == look.id { current.symbol = symbol }
    }

    func duplicate(_ look: Look) {
        saved.append(look.copy(named: "\(look.name) Copy"))
    }

    func delete(_ look: Look) {
        saved.removeAll { $0.id == look.id }
        if current.id == look.id {
            // Keep how things look; it just isn't a saved look any more.
            current.id = UUID()
        }
    }

    func moveSaved(from source: IndexSet, to destination: Int) {
        saved.move(fromOffsets: source, toOffset: destination)
    }

    /// Back to the stored version of the current look (or Knight Red if it was never saved).
    func revert() {
        apply(look(id: current.id) ?? .knightRed)
    }

    // MARK: - Import / export

    func exportData(for look: Look) throws -> Data {
        try look.exportJSON()
    }

    /// Adds an imported look (always as a new saved look) and applies it.
    @discardableResult
    func importLook(from data: Data) throws -> Look {
        var look = try JSONDecoder().decode(Look.self, from: data)
        look.id = UUID()
        saved.append(look)
        apply(look)
        return look
    }

    // MARK: - Home

    var visibleHomeSections: [HomeSection] { homeOrder.filter { !hiddenHomeSections.contains($0) } }

    func setHomeSection(_ section: HomeSection, visible: Bool) {
        if visible { hiddenHomeSections.remove(section) } else { hiddenHomeSections.insert(section) }
    }

    func moveHomeSections(from source: IndexSet, to destination: Int) {
        homeOrder.move(fromOffsets: source, toOffset: destination)
    }

    func resetHome() {
        homeOrder = HomeSection.allCases
        hiddenHomeSections = []
    }

    // MARK: - Artwork-driven colors

    /// Called by the shell when the playing song changes.
    func updateArtwork(_ palette: ArtworkPalette?) {
        guard let palette, !palette.colors.isEmpty else {
            artworkAccent = nil
            artworkColors = []
            return
        }
        artworkColors = palette.swiftUIColors
        let vivid = Self.vividColor(in: palette.colors)
        let hex = vivid.hexString
        guard hex != lastArtworkAccentHex else { return }
        lastArtworkAccentHex = hex
        withAnimation(.smooth(duration: 0.8)) { artworkAccent = Color(vivid) }
    }

    /// A look built around a cover: its most vivid color as the accent, everything else from the current look.
    func lookFromAlbum(named albumName: String, palette: ArtworkPalette) -> Look {
        var look = current.copy(named: albumName)
        look.symbol = "opticaldisc.fill"
        look.accentSource = .fixed
        look.accentHex = Self.vividColor(in: palette.colors).hexString
        look.lyricsHighlight = .artwork
        look.artworkGlow = true
        return look
    }

    /// The most saturated palette color, lifted so it reads as an accent on black.
    static func vividColor(in colors: [UIColor]) -> UIColor {
        var best = UIColor(red: 0.98, green: 0.176, blue: 0.282, alpha: 1)
        var bestScore: CGFloat = -1
        for color in colors {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let score = s * 0.7 + b * 0.3
            if score > bestScore {
                bestScore = score
                best = UIColor(hue: h, saturation: max(s, 0.55), brightness: max(b, 0.85), alpha: 1)
            }
        }
        return best
    }

    // MARK: - Surprise

    /// A random but tasteful look: harmonious accent, random player, type and layout choices.
    func surpriseLook() -> Look {
        var look = Look.knightRed
        look.id = UUID()
        let adjectives = ["Midnight", "Velvet", "Electric", "Desert", "Cosmic", "Golden", "Silent", "Neon", "Atlas", "Sahara", "Ocean", "Ember"]
        let nouns = ["Groove", "Echo", "Bloom", "Pulse", "Mirage", "Drift", "Tide", "Spark", "Lantern", "Orbit", "Dune", "Nova"]
        look.name = "\(adjectives.randomElement() ?? "Cosmic") \(nouns.randomElement() ?? "Echo")"
        look.symbol = ["wand.and.stars", "dice.fill", "sparkles", "moon.stars.fill", "flame.fill", "leaf.fill", "drop.fill", "star.fill"].randomElement() ?? "sparkles"
        let hue = CGFloat.random(in: 0...1)
        look.accentHex = UIColor(hue: hue, saturation: .random(in: 0.6...0.95), brightness: .random(in: 0.85...1), alpha: 1).hexString
        look.accentSource = Int.random(in: 0..<5) == 0 ? .artwork : .fixed
        look.appearance = current.appearance
        look.typeface = Look.Typeface.allCases.randomElement() ?? .standard
        look.typeWidth = [.standard, .standard, .condensed, .expanded].randomElement() ?? .standard
        look.backdrop = Look.Backdrop.allCases.randomElement() ?? .palette
        look.artworkShape = [.card, .card, .vinyl, .circle].randomElement() ?? .card
        look.artworkRadius = [0, 8, 12, 20, 28, 36].randomElement() ?? 12
        look.artworkGlow = .random()
        look.pulse = Look.Pulse.allCases.randomElement() ?? .off
        look.shrinkWhenPaused = .random()
        look.lyricsScale = [0.9, 1, 1.1, 1.25].randomElement() ?? 1
        look.lyricsAlignment = .random() ? .leading : .center
        look.lyricsHighlight = Look.LyricsHighlight.allCases.randomElement() ?? .white
        look.lyricsBlur = .random()
        look.lyricsGlow = .random()
        look.tileRadius = [0, 4, 8, 14, 20].randomElement() ?? 8
        look.artistShape = .random() ? .circle : .rounded
        return look
    }

    func applySurprise() {
        apply(surpriseLook())
        Haptics.success()
    }

    // MARK: - Day / night

    /// Switches to the day or night look when the period changed since the last check (manual edits in between
    /// are kept until the next switch).
    func applyScheduleIfNeeded(now: Date = Date()) {
        guard scheduleEnabled else { return }
        let hour = Calendar.current.component(.hour, from: now)
        let isDay = dayStartHour <= nightStartHour
            ? (hour >= dayStartHour && hour < nightStartHour)
            : !(hour >= nightStartHour && hour < dayStartHour)
        guard isDay != lastScheduledPeriod else { return }
        lastScheduledPeriod = isDay
        let target = look(id: isDay ? dayLookId : nightLookId) ?? .knightRed
        guard target.id != current.id else { return }
        withAnimation(.smooth(duration: 1.2)) { current = target }
    }

    // MARK: - Persistence

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Log.app.error("Couldn't save \(key): \(error)")
        }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

extension UIColor {
    /// "#RRGGBB" in sRGB.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
