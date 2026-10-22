import AVFoundation
import Foundation

/// Owns the AVAudioSession (.playback) and translates system notifications into engine callbacks.
@MainActor
final class AudioSessionController {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    var onRouteLost: (() -> Void)?
    var onNewDeviceAvailable: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var lastInterruptionReason: AVAudioSession.InterruptionReason?

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let reasonVal = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let reason = reasonVal.flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options, reason: reason) }
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reason: reason) }
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMediaServicesReset?() }
        })
    }

    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            PlaybackLog.logger.error("Audio session activation failed: \(error.localizedDescription)")
        }
    }

    private func handleInterruption(type: UInt?, options: UInt?, reason: AVAudioSession.InterruptionReason?) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            lastInterruptionReason = reason
            onInterruptionBegan?()
        case .ended:
            let effectiveReason = reason ?? lastInterruptionReason
            lastInterruptionReason = nil
            let opts = AVAudioSession.InterruptionOptions(rawValue: options ?? 0)
            let disallowResume = effectiveReason == .routeDisconnected || effectiveReason == .appWasSuspended
            let shouldResume = opts.contains(.shouldResume) && !disallowResume
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: UInt?) {
        guard let reason, let why = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
        switch why {
        case .oldDeviceUnavailable:
            onRouteLost?()
        case .newDeviceAvailable:
            onNewDeviceAvailable?()
        default:
            break
        }
    }
}
