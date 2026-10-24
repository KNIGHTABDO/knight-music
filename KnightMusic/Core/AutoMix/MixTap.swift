import AVFoundation
import MediaToolbox
import os

/// Keyframed automation for one deck (gain, high-pass, low-pass) on that item's media timeline.
/// Written from the main actor, read on the real-time audio thread (lock-free on contention).
final class MixAutomation: @unchecked Sendable {
    struct Curve: Sendable {
        var times: [Double]
        var values: [Float]

        init?(_ frames: [[Double]]) {
            let valid = frames.filter { $0.count >= 2 }.sorted { $0[0] < $1[0] }
            guard !valid.isEmpty else { return nil }
            times = valid.map { $0[0] }
            values = valid.map { Float($0[1]) }
        }

        /// Linear between keyframes (filters interpolate in octaves), flat before the first and after the last.
        func value(at t: Double, logarithmic: Bool = false) -> Float {
            if t <= times[0] { return values[0] }
            if t >= times[times.count - 1] { return values[values.count - 1] }
            var lo = 0, hi = times.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if times[mid] <= t { lo = mid } else { hi = mid }
            }
            let u = Float((t - times[lo]) / max(times[hi] - times[lo], 1e-9))
            if logarithmic {
                return exp(log(max(values[lo], 1)) * (1 - u) + log(max(values[hi], 1)) * u)
            }
            return values[lo] + (values[hi] - values[lo]) * u
        }
    }

    struct Program: Sendable {
        var gain: Curve?
        var hpf: Curve?
        var lpf: Curve?
        /// Short crossover envelope while a deck hands over to its twin at another tempo (see Retempo).
        var fade: Curve?
        var isIdentity: Bool { gain == nil && hpf == nil && lpf == nil && fade == nil }
    }

    private let state = OSAllocatedUnfairLock(initialState: Program())

    func set(deck: AutoMixPlan.Deck) {
        let gain = Curve(deck.gain), hpf = Curve(deck.hpf), lpf = Curve(deck.lpf)
        state.withLock { $0 = Program(gain: gain, hpf: hpf, lpf: lpf, fade: $0.fade) }
    }

    /// Takes over another deck's curves (a twin of the same item continues its automation).
    func adopt(_ other: MixAutomation) {
        let program = other.state.withLock { $0 }
        state.withLock { $0 = Program(gain: program.gain, hpf: program.hpf, lpf: program.lpf, fade: $0.fade) }
    }

    func setFade(_ frames: [[Double]]) {
        let fade = Curve(frames)
        state.withLock { $0.fade = fade }
    }

    func clearFade() {
        state.withLock { $0.fade = nil }
    }

    func clear() {
        state.withLock { $0 = Program() }
    }

    fileprivate func snapshot() -> Program? {
        state.withLockIfAvailable { $0 }
    }
}

/// Real-time state behind one MTAudioProcessingTap: biquad filters + smoothed gain driven by `MixAutomation`.
private final class MixTapContext {
    let automation: MixAutomation
    var sampleRate: Double = 44_100
    var supported = false
    var interleaved = false
    var channels = 2
    var program = MixAutomation.Program()
    var gain: Float = 1
    /// False until the first buffer: the gain then starts at its target instead of gliding from 1 (a twin deck
    /// starting under a fade-in would otherwise blip at full level).
    var primed = false
    var hp = FilterBank(), lp = FilterBank()
    var eq = PeakingBank()
    var clock: Double = .nan            // media time of the next frame, when the source doesn't say

    init(automation: MixAutomation) { self.automation = automation }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        supported = isFloat && format.mBitsPerChannel == 32
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channels = Int(max(format.mChannelsPerFrame, 1))
        hp = FilterBank(channels: channels)
        lp = FilterBank(channels: channels)
        eq = PeakingBank(channels: channels)
        gain = 1
        primed = false
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: CMTime) {
        if let latest = automation.snapshot() { program = latest }
        if let equalizer = Equalizer.snapshot() { eq.configure(equalizer, sampleRate: sampleRate) }
        let startTime = start.isValid && start.isNumeric ? start.seconds : clock
        if !startTime.isNaN { clock = startTime + Double(frames) / sampleRate }
        guard supported, frames > 0, !startTime.isNaN else { return }
        if program.isIdentity && gain == 1 && hp.idle && lp.idle && !eq.active {
            primed = true
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let block = 64
        var offset = 0
        while offset < frames {
            let count = min(block, frames - offset)
            let t = startTime + Double(offset + count / 2) / sampleRate
            let targetGain = (program.gain?.value(at: t) ?? 1) * (program.fade?.value(at: t) ?? 1)
            if !primed {
                gain = targetGain
                primed = true
            }
            hp.configure(highPass: true, cutoff: program.hpf?.value(at: t, logarithmic: true), sampleRate: sampleRate)
            lp.configure(highPass: false, cutoff: program.lpf?.value(at: t, logarithmic: true), sampleRate: sampleRate)
            let g0 = gain, step = (targetGain - gain) / Float(count)
            if interleaved, let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                for f in 0..<count {
                    let g = g0 + step * Float(f + 1)
                    for c in 0..<channels {
                        let i = (offset + f) * channels + c
                        data[i] = eq.run(c, lp.run(c, hp.run(c, data[i]))) * g
                    }
                }
            } else {
                for (c, buffer) in buffers.enumerated() where c < channels {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<count {
                        let i = offset + f
                        data[i] = eq.run(c, lp.run(c, hp.run(c, data[i]))) * (g0 + step * Float(f + 1))
                    }
                }
            }
            gain = targetGain
            offset += count
        }
    }
}

/// One RBJ biquad (Butterworth Q) per channel. A deck with a filter curve runs its filter the whole time the curve
/// is installed — fully open at the curve's ends (10 Hz high-pass, ~20 kHz low-pass), so sweeps never switch a filter
/// in or out while it is audible; without a curve it is bypassed.
private struct FilterBank {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: [Float], x2: [Float], y1: [Float], y2: [Float]
    private var cutoff: Float = 0
    private(set) var idle = true

    init(channels: Int = 2) {
        x1 = Array(repeating: 0, count: channels); x2 = x1; y1 = x1; y2 = x1
    }

    mutating func configure(highPass: Bool, cutoff requested: Float?, sampleRate: Double) {
        guard let requested else {
            if !idle { reset() }
            idle = true
            return
        }
        let fc = min(max(requested, 10), Float(sampleRate) * 0.45)
        if !idle, abs(fc - cutoff) < cutoff * 0.003 { return }
        if idle { reset() }
        idle = false
        cutoff = fc
        let w = 2 * Float.pi * fc / Float(sampleRate)
        let alpha = sin(w) / (2 * 0.7071)
        let cosw = cos(w)
        let a0 = 1 + alpha
        if highPass {
            b0 = (1 + cosw) / 2 / a0; b1 = -(1 + cosw) / a0; b2 = b0
        } else {
            b0 = (1 - cosw) / 2 / a0; b1 = (1 - cosw) / a0; b2 = b0
        }
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    @inline(__always)
    mutating func run(_ c: Int, _ x: Float) -> Float {
        if idle { return x }
        let y = b0 * x + b1 * x1[c] + b2 * x2[c] - a1 * y1[c] - a2 * y2[c]
        x2[c] = x1[c]; x1[c] = x
        y2[c] = y1[c]; y1[c] = y
        return y
    }

    private mutating func reset() {
        for c in x1.indices { x1[c] = 0; x2[c] = 0; y1[c] = 0; y2[c] = 0 }
    }
}

/// The user's graphic EQ: one RBJ peaking biquad per band and channel, about an octave wide, after a preamp that
/// keeps boosted bands from clipping. Coefficients are recomputed only when `Equalizer.Program.revision` changes.
private struct PeakingBank {
    private let bands = Equalizer.frequencies.count
    private let channels: Int
    private var coefficients: [Float]      // b0 b1 b2 a1 a2 per band
    private var memory: [Float]            // x1 x2 y1 y2 per channel and band
    private var revision = -1
    private var preamp: Float = 1
    private(set) var active = false

    init(channels: Int = 2) {
        self.channels = channels
        coefficients = [Float](repeating: 0, count: Equalizer.frequencies.count * 5)
        memory = [Float](repeating: 0, count: channels * Equalizer.frequencies.count * 4)
    }

    mutating func configure(_ program: Equalizer.Program, sampleRate: Double) {
        guard program.revision != revision else { return }
        revision = program.revision
        let wasActive = active
        active = program.isActive && program.gains.count == bands
        guard active else { return }
        if !wasActive { for i in memory.indices { memory[i] = 0 } }
        preamp = pow(10, program.preampDB / 20)
        let q: Float = 1.41
        for band in 0..<bands {
            let k = band * 5
            let frequency = Equalizer.frequencies[band]
            guard frequency < Float(sampleRate) * 0.45 else {
                coefficients[k] = 1; coefficients[k + 1] = 0; coefficients[k + 2] = 0
                coefficients[k + 3] = 0; coefficients[k + 4] = 0
                continue
            }
            let a = pow(10, program.gains[band] / 40)
            let w = 2 * Float.pi * frequency / Float(sampleRate)
            let alpha = sin(w) / (2 * q)
            let cosw = cos(w)
            let a0 = 1 + alpha / a
            coefficients[k] = (1 + alpha * a) / a0
            coefficients[k + 1] = -2 * cosw / a0
            coefficients[k + 2] = (1 - alpha * a) / a0
            coefficients[k + 3] = -2 * cosw / a0
            coefficients[k + 4] = (1 - alpha / a) / a0
        }
    }

    @inline(__always)
    mutating func run(_ c: Int, _ x: Float) -> Float {
        guard active, c < channels else { return x }
        var v = x * preamp
        for band in 0..<bands {
            let k = band * 5, m = (c * bands + band) * 4
            let y = coefficients[k] * v + coefficients[k + 1] * memory[m] + coefficients[k + 2] * memory[m + 1]
                - coefficients[k + 3] * memory[m + 2] - coefficients[k + 4] * memory[m + 3]
            memory[m + 1] = memory[m]; memory[m] = v
            memory[m + 3] = memory[m + 2]; memory[m + 2] = y
            v = y
        }
        return v
    }
}

/// Attaches an AutoMix processing tap to a player item's audio track.
enum MixTap {
    /// False when the item has no audio track yet or the tap can't be created (the deck then mixes by volume).
    @MainActor
    static func attach(to item: AVPlayerItem, automation: MixAutomation) async -> Bool {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return false }
        let context = MixTapContext(automation: automation)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: numericCast(kMTAudioProcessingTapCallbacksVersion_0),
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                numericCast(kMTAudioProcessingTapCreationFlag_PreEffects), &tap)
        guard status == noErr, let tap else {
            Unmanaged<MixTapContext>.fromOpaque(callbacks.clientInfo!).release()
            Log.playback.warning("AutoMix tap unavailable (\(status))")
            return false
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        return true
    }
}

private func context(of tap: MTAudioProcessingTap) -> MixTapContext {
    Unmanaged<MixTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<MixTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    context(of: tap).prepare(format.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    var range = CMTimeRange()
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
    context(of: tap).process(bufferList, frames: Int(framesOut.pointee), start: range.start)
}
