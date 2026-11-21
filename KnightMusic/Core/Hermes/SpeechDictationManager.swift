import Foundation
import Speech
import AVFoundation

/// Manages on-device dictation using SFSpeechRecognizer and AVAudioEngine.
@MainActor @Observable
final class SpeechDictationManager: NSObject {
    var isRecording = false
    var errorMessage: String?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Set while permission prompts are pending; `stop()` clears it so a late grant doesn't start the mic.
    private var pendingStartID: UUID?
    private let audioEngine = AVAudioEngine()

    override init() {
        super.init()
        // Locale.current may be a region the recognizer doesn't support (e.g. en_MA); fall back to US English.
        if let local = SFSpeechRecognizer(locale: Locale.current), local.isAvailable {
            speechRecognizer = local
        } else {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
    }

    func toggle(onText: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            start(onText: onText)
        }
    }

    func start(onText: @escaping (String) -> Void) {
        guard !isRecording, pendingStartID == nil else { return }
        let startID = UUID()
        pendingStartID = startID
        errorMessage = nil

        // Permission callbacks arrive on arbitrary queues: build them outside the main actor and hop back.
        SFSpeechRecognizer.requestAuthorization(Self.authorizationHandler { [weak self] authorized in
            guard let self, self.pendingStartID == startID else { return }
            guard authorized else {
                self.pendingStartID = nil
                self.errorMessage = "Speech recognition access denied"
                return
            }
            AVAudioApplication.requestRecordPermission(completionHandler: Self.permissionHandler { [weak self] granted in
                guard let self, self.pendingStartID == startID else { return }
                guard granted else {
                    self.pendingStartID = nil
                    self.errorMessage = "Microphone access denied"
                    return
                }
                self.beginRecording(onText: onText)
            })
        })
    }

    private nonisolated static func authorizationHandler(
        _ body: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { status in
            let authorized = status == .authorized
            Task { @MainActor in body(authorized) }
        }
    }

    private nonisolated static func permissionHandler(
        _ body: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable (Bool) -> Void {
        { granted in Task { @MainActor in body(granted) } }
    }

    /// The tap runs on CoreAudio's realtime thread, so it must not inherit the main actor's isolation.
    private nonisolated static func makeTap(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private func beginRecording(onText: @escaping (String) -> Void) {
        stop()

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer is not available"
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            // playAndRecord keeps the app's playback session usable; stop() switches back to .playback.
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Prefer on-device, but don't *require* it: requiring fails instantly when the language model
            // isn't downloaded, which made the mic look dead.
            request.requiresOnDeviceRecognition = false
            if #available(iOS 13.0, *) { request.addsPunctuation = true }
            self.recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            // No input route (e.g. mic in use by a call) reports a 0 Hz / 0 channel format; installTap would crash.
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                errorMessage = "Microphone is not available right now"
                stop()
                return
            }
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat, block: Self.makeTap(for: request))

            audioEngine.prepare()
            try audioEngine.start()

            isRecording = true
            errorMessage = nil

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result {
                        let text = result.bestTranscription.formattedString
                        onText(text)
                    }
                    if let error, self?.isRecording == true, result == nil {
                        self?.errorMessage = "Dictation failed: \(error.localizedDescription)"
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self?.stop()
                    }
                }
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        pendingStartID = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false

        // Hand the session back to music playback instead of deactivating it (which would stop the player).
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            do {
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                Log.playback.error("Failed to restore playback audio session: \(error)")
            }
        }
    }
}
