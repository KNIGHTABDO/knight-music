import Foundation
import Observation

/// The two apps living in Duet: Knight Music and Streamora.
enum DuetWorld: String, Sendable {
    case music, movies

    var other: DuetWorld { self == .music ? .movies : .music }
    var appName: String { self == .music ? "Knight Music" : "Streamora" }
    var symbol: String { self == .music ? "music.note" : "film" }
}

/// Duet preferences, persisted in UserDefaults (and so included in the Navidrome settings backup).
@MainActor @Observable
final class DuetSettings {
    static let shared = DuetSettings()

    /// Ask with the glass pill before switching (shake again or tap Switch). Off switches on the first shake.
    var confirmSwitch: Bool { didSet { defaults.set(confirmSwitch, forKey: Keys.confirm) } }
    /// Music pauses while a movie plays and picks up again when the movie ends or you switch back.
    var intermission: Bool { didSet { defaults.set(intermission, forKey: Keys.intermission) } }
    /// Open on the side you were using when the app was closed.
    var reopenLastSide: Bool { didSet { defaults.set(reopenLastSide, forKey: Keys.reopen) } }
    var lastWorld: DuetWorld { didSet { defaults.set(lastWorld.rawValue, forKey: Keys.last) } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let confirm = "duet.confirmSwitch", intermission = "duet.intermission"
        static let reopen = "duet.reopenLastSide", last = "duet.lastWorld"
    }

    private init() {
        let d = UserDefaults.standard
        confirmSwitch = d.object(forKey: Keys.confirm) as? Bool ?? true
        intermission = d.object(forKey: Keys.intermission) as? Bool ?? true
        reopenLastSide = d.object(forKey: Keys.reopen) as? Bool ?? true
        lastWorld = DuetWorld(rawValue: d.string(forKey: Keys.last) ?? "") ?? .music
    }
}
