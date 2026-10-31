import AVFoundation
import Foundation
import GRDB

/// Owns all mic recognition. Every entry point (sheet, Control Center) goes through here because iOS gives a process
/// one AVAudioSession: two recognizers reconfiguring it is what produced the '!int' activation failures.
@MainActor
@Observable
final class ShazamService {
    enum RecognitionState: Equatable {
        case idle
        case listening
        case matched(RecognizedTrack)
        case notFound
        case error(String)
    }

    private(set) var state: RecognitionState = .idle
    private(set) var currentTrack: RecognizedTrack?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var run: Task<Bool, Never>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var collector: PCMClipCollector?
    @ObservationIgnored private var engineObserver: NSObjectProtocol?
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var playerWasPlaying = false

    func configure(app: AppModel) {
        self.app = app
        publishCredentials()
        app.addSessionObserver(fireImmediately: false) { [weak self] _ in self?.publishCredentials() }
    }

    // MARK: - Entry points

    func startListening() {
        guard run == nil else { return }
        run = Task { await perform(liveActivity: false, allowDeferral: false) }
    }

    /// For Control Center. false means iOS refused to start from the background and the caller should foreground the app.
    func recognizeInBackground() async -> Bool {
        if let run { return await run.value }
        let task = Task { await perform(liveActivity: true, allowDeferral: true) }
        run = task
        return await task.value
    }

    func recognizeInForeground() async {
        if let run { _ = await run.value; return }
        let task = Task { await perform(liveActivity: true, allowDeferral: false) }
        run = task
        _ = await task.value
    }

    func stopListening() {
        guard let active = run else { return }
        active.cancel()
        run = nil
        stopCapture()
        state = .idle
        Task { await RecognitionActivityManager.shared.endActivity() }
    }

    /// Picks up a match the broadcast extension found while the app was away. true when there's one to show.
    func consumeBroadcastResult() -> Bool {
        guard let id = BroadcastResultMailbox.take() else { return false }
        let store = RecognizedTracksStore.shared
        store.reload()
        guard let track = store.tracks.first(where: { $0.id == id }) else { return false }
        // The sheet's mic run is usually still going; left alone, its outcome would overwrite this match.
        stopListening()
        currentTrack = track
        state = .matched(track)
        return true
    }

    // MARK: - Recognition

    private func perform(liveActivity: Bool, allowDeferral: Bool) async -> Bool {
        state = .listening
        currentTrack = nil
        Log.app.info("Recognition starting (liveActivity=\(liveActivity), allowDeferral=\(allowDeferral))")

        publishCredentials()
        guard let credentials = RecognitionCredentials.load() ?? makeCredentials() else {
            return conclude(.failed("Sign in to your server to identify songs."), liveActivity: false)
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined where allowDeferral:
            return defer_()
        default:
            guard await AVAudioApplication.requestRecordPermission() else {
                return conclude(.failed("Allow microphone access for Knight Music in Settings to identify songs."), liveActivity: false)
            }
        }
        if Task.isCancelled { return true }

        if liveActivity, !RecognitionActivityManager.shared.startListening() {
            if allowDeferral { return defer_() }
        }

        let collector = PCMClipCollector()
        do {
            try startCapture(into: collector)
        } catch {
            Log.app.error("Recognition capture failed: \(error.localizedDescription)")
            stopCapture()
            if allowDeferral {
                await RecognitionActivityManager.shared.endActivity()
                return defer_()
            }
            return conclude(.failed(error.localizedDescription), liveActivity: liveActivity)
        }

        let outcome = await RecognitionLoop.run(collector: collector, credentials: credentials)
        guard !Task.isCancelled else { return true }
        stopCapture()
        return conclude(outcome, liveActivity: liveActivity)
    }

    private func defer_() -> Bool {
        run = nil
        state = .idle
        return false
    }

    private func conclude(_ outcome: RecognitionOutcome, liveActivity: Bool) -> Bool {
        run = nil
        switch outcome {
        case .matched(let track):
            currentTrack = track
            state = .matched(track)
            RecognizedTracksStore.shared.add(track)
            Haptics.impact(.medium)
            if liveActivity {
                Task {
                    let songId = await resolveLocalMatch(title: track.title, artist: track.artist)?.id
                    await RecognitionActivityManager.shared.updateMatched(
                        title: track.title, artist: track.artist, artworkURL: track.artworkURL, localSongId: songId
                    )
                }
            }
        case .notFound:
            state = .notFound
            if liveActivity { Task { await RecognitionActivityManager.shared.updateNotFound() } }
        case .silent:
            let message = "The microphone didn't hear anything. Turn the music up or move closer. For audio playing on this device through headphones, use Listen to This Device."
            state = .error(message)
            if liveActivity { Task { await RecognitionActivityManager.shared.updateError("Heard nothing") } }
        case .failed(let message):
            state = .error(message)
            if liveActivity { Task { await RecognitionActivityManager.shared.updateError(message) } }
        case .cancelled:
            state = .idle
        }
        return true
    }

    // MARK: - Audio

    private struct CaptureError: LocalizedError {
        var step: String
        var underlying: NSError

        var errorDescription: String? {
            switch AVAudioSession.ErrorCode(rawValue: underlying.code) {
            case .cannotInterruptOthers, .cannotStartRecording:
                "iOS wouldn't let the microphone start from the background (\(step)). Open Knight Music and try again."
            case .insufficientPriority:
                "Another app, probably a call, is using the microphone. Try again when it's done."
            default:
                "The microphone couldn't start (\(step), code \(underlying.code))."
            }
        }
    }

    private func startCapture(into collector: PCMClipCollector) throws {
        playerWasPlaying = app?.player.userWantsPlaying ?? false
        capturing = true
        let session = AVAudioSession.sharedInstance()
        func attempt(_ step: String, _ body: () throws -> Void) throws {
            do { try body() } catch { throw CaptureError(step: step, underlying: error as NSError) }
        }
        // mixWithOthers leaves the other app's audio playing. No .allowBluetooth: that would drop AirPods to call
        // quality and listen through their mic, which can't hear the room.
        try attempt("category") {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        }
        try attempt("activate") { try session.setActive(true) }
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
        }
        self.collector = collector
        try attempt("engine") { try startEngine() }
    }

    private func startEngine() throws {
        guard let collector else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFormatUnsupportedDataFormatError))
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(into: collector))
        engine.prepare()
        try engine.start()
        self.engine = engine
        // A route change (headphones plugged, AirPods connecting) stops the engine silently.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }
    }

    /// nonisolated so the realtime audio thread never runs a closure that inherited MainActor isolation.
    private nonisolated static func tap(into collector: PCMClipCollector) -> AVAudioNodeTapBlock {
        { buffer, _ in collector.append(buffer) }
    }

    private func restartEngine() {
        guard capturing else { return }
        Log.app.info("Recognition restarting capture after audio route change")
        tearDownEngine()
        do {
            try startEngine()
        } catch {
            Log.app.error("Recognition couldn't restart capture: \(error.localizedDescription)")
        }
    }

    private func tearDownEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func stopCapture() {
        guard capturing else { return }
        capturing = false
        tearDownEngine()
        collector = nil
        let session = AVAudioSession.sharedInstance()
        if playerWasPlaying {
            app?.player.audioSession.activate()
            if let player = app?.player, !player.isPlaying { player.resume() }
        } else {
            // Reactivating a non-mixable session here would cut off whatever app the user is listening to.
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Log.app.warning("Recognition couldn't release the audio session: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Credentials

    private func makeCredentials() -> RecognitionCredentials? {
        guard let client = app?.client else { return nil }
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var addresses = [client.baseURL]
        for address in app?.accounts.active?.addresses ?? [] where !addresses.contains(address) {
            addresses.append(address)
        }
        return RecognitionCredentials(
            addresses: addresses,
            username: client.username,
            token: SubsonicClient.md5(client.password + salt),
            salt: salt
        )
    }

    private func publishCredentials() {
        makeCredentials()?.save()
    }

    // MARK: - Library

    /// Only claims "In Your Library" when the artist agrees too; a title alone matches covers and unrelated songs.
    func resolveLocalMatch(title: String, artist: String) async -> Song? {
        guard let database = app?.library.database else { return nil }
        let wanted = Self.baseTitle(title)
        let leadArtist = Self.leadArtist(artist)
        return try? await database.pool.read { db in
            try Song
                .filter(Column("title").like("%\(wanted)%"))
                .fetchAll(db)
                .first { song in
                    guard let songArtist = song.artist else { return false }
                    return songArtist.localizedCaseInsensitiveContains(leadArtist)
                        || leadArtist.localizedCaseInsensitiveContains(songArtist)
                }
        }
    }

    /// "Song (feat. X) [Remastered]" -> "Song"
    private nonisolated static func baseTitle(_ title: String) -> String {
        let cut = title.firstIndex { $0 == "(" || $0 == "[" } ?? title.endIndex
        let base = title[..<cut].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? title : base
    }

    /// Shazam lists collaborators in one string: "A & B", "A feat. B".
    private nonisolated static func leadArtist(_ artist: String) -> String {
        var lead = artist
        for separator in [" & ", " feat. ", " Feat. ", " ft. ", ", ", " x ", " X "] {
            if let range = lead.range(of: separator) { lead = String(lead[..<range.lowerBound]) }
        }
        return lead.trimmingCharacters(in: .whitespaces)
    }
}
