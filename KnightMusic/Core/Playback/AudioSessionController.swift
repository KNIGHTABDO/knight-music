import AVFoundation
import Foundation

/// Owns the AVAudioSession (.playback) and translates system notifications into engine callbacks.
@MainActor
final class AudioSessionController {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    var onRouteLost: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
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

    private func handleInterruption(type: UInt?, options: UInt?) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: options ?? 0)
            onInterruptionEnded?(opts.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: UInt?) {
        guard let reason, let why = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
        if why == .oldDeviceUnavailable { onRouteLost?() }
    }
}
