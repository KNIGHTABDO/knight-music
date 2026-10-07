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
        guard !isRecording else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else {
                    self?.errorMessage = "Speech recognition access denied"
                    return
                }
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { [weak self] granted in
                        Task { @MainActor in
                            guard granted else {
                                self?.errorMessage = "Microphone access denied"
                                return
                            }
                            self?.beginRecording(onText: onText)
                        }
                    }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                        Task { @MainActor in
                            guard granted else {
                                self?.errorMessage = "Microphone access denied"
                                return
                            }
                            self?.beginRecording(onText: onText)
                        }
                    }
                }

            }
        }
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
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

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
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
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
