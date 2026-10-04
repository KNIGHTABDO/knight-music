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
        /// Playback rate during the overlap (time-stretch, pitch kept). A reaches it through `rateRamp` before
        /// B comes in when the two tempos meet halfway.
        var rate: Double?
        var gain: [[Double]]
        var hpf: [[Double]]
        var lpf: [[Double]]
        /// `[mediaTime, rate]` steps. A: easing into the blend tempo before B starts. B: easing back to its own
        /// tempo once A is gone.
        var rateRamp: [[Double]]?
    }

    static let supportedVersion = 3

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
        let rates = [a.rate ?? 1, b.rate ?? 1] + (a.rateRamp ?? []).compactMap { $0.last } + (b.rateRamp ?? []).compactMap { $0.last }
        return a.start < handoff && handoff <= stop && b.start >= 0 && rates.allSatisfy { $0 > 0.8 && $0 < 1.25 }
    }
}
