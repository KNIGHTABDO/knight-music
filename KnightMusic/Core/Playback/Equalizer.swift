import Foundation
import os

/// Ten-band graphic equalizer: band layout, presets, and the live program the audio taps read.
enum Equalizer {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let range: ClosedRange<Double> = -12...12
    static let flat = [Double](repeating: 0, count: frequencies.count)

    struct Preset: Identifiable, Hashable {
        let id: String
        let name: String
        let gains: [Double]
    }

    static let presets: [Preset] = [
        Preset(id: "flat", name: "Flat", gains: flat),
        Preset(id: "acoustic", name: "Acoustic", gains: [4.5, 4.5, 3.5, 1, 1.5, 1.5, 3, 3.5, 3, 1.5]),
        Preset(id: "bassBooster", name: "Bass Booster", gains: [5.5, 4.5, 3.5, 2.5, 1, 0, 0, 0, 0, 0]),
        Preset(id: "bassReducer", name: "Bass Reducer", gains: [-5.5, -4.5, -3.5, -2.5, -1, 0, 0, 0, 0, 0]),
        Preset(id: "classical", name: "Classical", gains: [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5]),
        Preset(id: "dance", name: "Dance", gains: [3.5, 6.5, 5, 0, 2, 3.5, 5, 4.5, 3.5, 0]),
        Preset(id: "electronic", name: "Electronic", gains: [4, 3.5, 1, 0, -2, 2, 1, 1.5, 4, 5]),
        Preset(id: "hipHop", name: "Hip-Hop", gains: [5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        Preset(id: "jazz", name: "Jazz", gains: [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]),
        Preset(id: "lateNight", name: "Late Night", gains: [-3, -2, -1, 0, 1.5, 2, 2, 1, 0, -1]),
        Preset(id: "loudness", name: "Loudness", gains: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        Preset(id: "pop", name: "Pop", gains: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        Preset(id: "rock", name: "Rock", gains: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        Preset(id: "smallSpeakers", name: "Small Speakers", gains: [5.5, 4.5, 4, 2.5, 2.5, 1, 0, -1.5, -3, -4]),
        Preset(id: "spokenWord", name: "Spoken Word", gains: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4.5, 2.5, 0]),
        Preset(id: "trebleBooster", name: "Treble Booster", gains: [0, 0, 0, 0, 0, 1, 2.5, 3.5, 4.5, 5.5]),
        Preset(id: "trebleReducer", name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1, -2.5, -3.5, -4.5, -5.5]),
        Preset(id: "vocalBooster", name: "Vocal Booster", gains: [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5]),
    ]

    static func preset(id: String) -> Preset? { presets.first { $0.id == id } }

    /// What the audio taps apply. `revision` changes on every update so the real-time thread recomputes its filters.
    struct Program: Sendable {
        var enabled = false
        var gains: [Float] = []
        var revision = 0

        var isActive: Bool { enabled && gains.contains { abs($0) > 0.05 } }
        /// Headroom so boosted bands don't clip.
        var preampDB: Float { -max(gains.max() ?? 0, 0) }
    }

    private static let state = OSAllocatedUnfairLock(initialState: Program())

    static func apply(enabled: Bool, gains: [Float]) {
        let normalized = gains.count == frequencies.count ? gains : [Float](repeating: 0, count: frequencies.count)
        state.withLock { program in
            guard program.enabled != enabled || program.gains != normalized else { return }
            program = Program(enabled: enabled, gains: normalized, revision: program.revision + 1)
        }
    }

    /// Non-blocking read for the audio thread (nil while the main thread is writing).
    static func snapshot() -> Program? {
        state.withLockIfAvailable { $0 }
    }
}
