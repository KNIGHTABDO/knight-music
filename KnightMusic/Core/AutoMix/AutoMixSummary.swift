import Foundation

/// The transition the player is going to make next (or is making), for the AutoMix preview.
struct PlannedMix: Equatable {
    var plan: AutoMixPlan
    var from: Song
    var to: Song
}

/// The slice of a song's server-side analysis the AutoMix preview draws: tempo, key and per-bar loudness.
struct AutoMixTrackSummary: Decodable, Sendable, Equatable {
    struct Key: Decodable, Sendable, Equatable {
        var name: String
        var camelot: String
    }

    struct Bar: Decodable, Sendable, Equatable {
        var t: Double
        var db: Double
    }

    var duration: Double
    var bpm: Double?
    var key: Key?
    var bars: [Bar]
    var refDb: Double?
}
