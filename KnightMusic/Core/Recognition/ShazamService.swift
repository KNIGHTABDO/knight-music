import Foundation
import AVFoundation
#if canImport(ShazamKit)
import ShazamKit
#endif
import GRDB

@MainActor
@Observable
final class ShazamService: NSObject, @unchecked Sendable {
    enum RecognitionState: Equatable {
        case idle
        case listening
        case matching
        case matched(RecognizedTrack)
        case notFound
        case error(String)
    }

    private(set) var state: RecognitionState = .idle
    private(set) var currentTrack: RecognizedTrack?
    private(set) var localMatch: Song?
    var lastError: String?

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    #if canImport(ShazamKit)
    @ObservationIgnored private var session: SHSession?
    #endif
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
    }

    func startListening(library: LibraryRepository? = nil) {
        stopListening()
        state = .listening
        currentTrack = nil
        localMatch = nil
        lastError = nil
        RecognitionActivityManager.shared.startListening()

        #if canImport(ShazamKit)
        requestMicrophonePermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.state = .error("Microphone access is required to identify songs.")
                    return
                }
                self.beginCapture(library: library)
            }
        }
        #else
        state = .error("Music recognition is not supported on this platform.")
        #endif
    }

    func stopListening() {
        timeoutTask?.cancel()
        timeoutTask = nil

        #if canImport(ShazamKit)
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        session = nil

        // Restore playback audio session category so playback remains smooth
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.category != .playback {
            do {
                try audioSession.setCategory(.playback, mode: .default)
                try audioSession.setActive(true)
            } catch {
                Log.playback.error("Failed to restore audio session after Shazam: \(error)")
            }
        }
        #endif

        if case .listening = state {
            state = .idle
        }
    }

    #if canImport(ShazamKit)
    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        }
    }

    private func beginCapture(library: LibraryRepository?) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)

            let engine = AVAudioEngine()
            let newSession = SHSession()
            newSession.delegate = self
            self.session = newSession
            self.audioEngine = engine

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                state = .error("Microphone input format is invalid.")
                stopListening()
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { [weak self] buffer, time in
                self?.session?.matchStreamingBuffer(buffer, at: time)
            }

            engine.prepare()
            try engine.start()

            // 14-second timeout safety window
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if case .listening = self.state {
                    self.stopListening()
                    self.state = .notFound
                }
            }
        } catch {
            Log.app.error("Failed to start Shazam audio capture: \(error)")
            state = .error("Could not access microphone: \(error.localizedDescription)")
            stopListening()
        }
    }
    #endif

    func resolveLocalMatch(title: String, artist: String, library: LibraryRepository) async -> Song? {
        guard let database = library.database else { return nil }
        return try? await database.pool.read { db in
            let candidates = try Song
                .filter(Column("title").like("%\(title)%"))
                .fetchAll(db)
            if let direct = candidates.first(where: {
                guard let songArtist = $0.artist else { return false }
                return songArtist.localizedCaseInsensitiveContains(artist) ||
                       artist.localizedCaseInsensitiveContains(songArtist)
            }) {
                return direct
            }
            return candidates.first
        }
    }
}

#if canImport(ShazamKit)
extension ShazamService: SHSessionDelegate {
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        let track = RecognizedTrack(
            id: item.shazamID ?? UUID().uuidString,
            title: item.title ?? "Unknown Title",
            artist: item.artist ?? "Unknown Artist",
            album: item.subtitle,
            artworkURL: item.artworkURL,
            appleMusicURL: item.appleMusicURL,
            isrc: item.isrc
        )
        Task { @MainActor in
            self.stopListening()
            self.currentTrack = track
            self.state = .matched(track)
            RecognizedTracksStore.shared.add(track)
            await RecognitionActivityManager.shared.updateMatched(
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                localSongId: self.localMatch?.id
            )
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        Task { @MainActor in
            self.stopListening()
            if let error {
                Log.app.warning("Shazam didNotFindMatchFor error: \(error)")
                self.state = .notFound
            } else {
                self.state = .notFound
            }
            await RecognitionActivityManager.shared.updateNotFound()
        }
    }
}
#endif
