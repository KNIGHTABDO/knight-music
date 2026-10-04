import Foundation

/// A transition between two songs, computed by the AutoMix service on the Navidrome host.
/// Every time is in seconds of that deck's own media timeline; gains are linear, filters in Hz.
struct AutoMixPlan: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case beatmatch, crossfade, gapless
    }

    struct Deck: Codable, Equatable, Sendable {
        /// A: media time at which B must start. B: media time B starts playing from.
        var start: Double
        /// A only: when the app switches the current song to B.
        var handoff: Double?
        /// A only: after this A is silent and is stopped.
        var stop: Double?
        /// B only: playback rate during the overlap (time-stretch, pitch kept).
        var rate: Double?
        var gain: [[Double]]
        var hpf: [[Double]]
        var lpf: [[Double]]
        /// B only: `[mediaTime, rate]` steps easing B back to its own tempo once A is gone.
        var rateRamp: [[Double]]?
    }

    static let supportedVersion = 2

    var version: Int
    var mode: Mode
    var reason: String?
    var from: String?
    var to: String?
    /// False while one of the songs is still being analysed (the plan is a provisional crossfade).
    var final: Bool?
    var a: Deck?
    var b: Deck?

    /// Mixable plan: both decks present and internally consistent.
    var isMix: Bool {
        guard mode != .gapless, let a, let b, let stop = a.stop, let handoff = a.handoff else { return false }
        return a.start < handoff && handoff <= stop && b.start >= 0 && (b.rate ?? 1) > 0.5 && (b.rate ?? 1) < 2
    }
}
