import AVFoundation
import CoreMedia
import Foundation

/// What the broadcast extension needs to reach the server. Lives in the App Group because extensions can't read the
/// app's Keychain item; holds a salted token, never the password.
public struct RecognitionCredentials: Codable, Sendable {
    public var addresses: [URL]
    public var username: String
    public var token: String
    public var salt: String

    public init(addresses: [URL], username: String, token: String, salt: String) {
        self.addresses = addresses
        self.username = username
        self.token = token
        self.salt = salt
    }

    private static let key = "knightmusic.recognition_credentials"
    private static let appGroupID = "group.com.knightabdo.knightmusic"

    /// `UserDefaults(suiteName:)` succeeds even without the entitlement, so only the container proves sharing works.
    public static var isSharedStorageAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    public static func load() -> RecognitionCredentials? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecognitionCredentials.self, from: data)
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroupID)?.set(data, forKey: Self.key)
    }

    /// Same rule as `SubsonicClient.autoMixURL`: Funnel path on HTTPS, port 4534 on a direct LAN address.
    fileprivate var endpoints: [URL] {
        addresses.compactMap { address in
            guard var comps = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return nil }
            if let port = comps.port, port != 443 { comps.port = 4534 }
            comps.path = "/automix/v1/recognize"
            comps.queryItems = [
                URLQueryItem(name: "u", value: username),
                URLQueryItem(name: "t", value: token),
                URLQueryItem(name: "s", value: salt),
            ]
            return comps.url
        }
    }
}

public enum RecognitionClientError: LocalizedError {
    case unauthorized
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The server rejected your login. Sign in again in Settings."
        case .server(let message): message
        }
    }
}

public enum RecognitionClient {
    private struct Reply: Decodable {
        var match: Bool
        var id: String?
        var title: String?
        var artist: String?
        var album: String?
        var artworkURL: URL?
        var appleMusicURL: URL?
        var isrc: String?
        var error: String?
    }

    /// nil means the server answered and the clip matched nothing; a failed lookup always throws.
    public static func identify(wav: Data, credentials: RecognitionCredentials) async throws -> RecognizedTrack? {
        var lastError: Error = RecognitionClientError.server("No server address is configured.")
        for endpoint in credentials.endpoints {
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 12)
                request.httpMethod = "POST"
                request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await URLSession.shared.upload(for: request, from: wav)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 { throw RecognitionClientError.unauthorized }
                let reply = try? JSONDecoder().decode(Reply.self, from: data)
                guard status == 200, let reply else {
                    throw RecognitionClientError.server(reply?.error ?? "The server returned error \(status). Update it with deploy/install.sh.")
                }
                guard reply.match, let title = reply.title else { return nil }
                return RecognizedTrack(
                    id: reply.id ?? UUID().uuidString,
                    title: title,
                    artist: reply.artist ?? "Unknown Artist",
                    album: reply.album,
                    artworkURL: reply.artworkURL,
                    appleMusicURL: reply.appleMusicURL,
                    isrc: reply.isrc
                )
            } catch let error as RecognitionClientError {
                throw error
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}

public enum RecognitionOutcome: Sendable {
    case matched(RecognizedTrack)
    case notFound
    case silent
    case failed(String)
    case cancelled
}

public enum RecognitionLoop {
    /// Retries on a growing clip: most songs match within seconds, quiet or noisy rooms need more audio.
    private static let attemptOffsets = [5, 10, 16, 23, 30]
    private static let clipSeconds = 12
    private static let silenceRMS = 20.0

    public static func run(collector: PCMClipCollector, credentials: RecognitionCredentials) async -> RecognitionOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        var heardSound = false
        var failure: String?
        for offset in attemptOffsets {
            do {
                try await clock.sleep(until: start + .seconds(offset))
            } catch {
                return .cancelled
            }
            guard let clip = collector.clip(seconds: clipSeconds), clip.rms >= silenceRMS else { continue }
            heardSound = true
            do {
                if let track = try await RecognitionClient.identify(wav: clip.wav, credentials: credentials) {
                    return .matched(track)
                }
                failure = nil
            } catch RecognitionClientError.unauthorized {
                return .failed(RecognitionClientError.unauthorized.localizedDescription)
            } catch {
                if Task.isCancelled { return .cancelled }
                failure = error.localizedDescription
            }
        }
        if let failure { return .failed("Couldn't reach the recognition server: \(failure)") }
        return heardSound ? .notFound : .silent
    }
}

/// Converts whatever iOS delivers (mic tap, broadcast samples) to 16 kHz mono PCM and keeps the most recent seconds.
public final class PCMClipCollector: @unchecked Sendable {
    private static let sampleRate = 16_000
    private static let maxSeconds = 16
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []

    public init() {}

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let limit = Self.maxSeconds * Self.sampleRate
        if samples.count > limit * 2 { samples.removeFirst(samples.count - limit) }
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        // ReplayKit's app audio is big-endian Int16, which AVAudioPCMBuffer can't represent: copy, then swap to native.
        let isBigEndianInt16 = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 && asbd.mBitsPerChannel == 16
        let format = isBigEndianInt16
            ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: true)
            : AVAudioFormat(cmAudioFormatDescription: description)
        guard frames > 0, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }
        if isBigEndianInt16, let data = buffer.int16ChannelData?[0] {
            for index in 0..<(frames * Int(asbd.mChannelsPerFrame)) { data[index] = Int16(bigEndian: data[index]) }
        }
        append(buffer)
    }

    /// nil until there's enough audio for a fingerprint.
    public func clip(seconds: Int) -> (wav: Data, rms: Double)? {
        lock.lock()
        let recent = Array(samples.suffix(seconds * Self.sampleRate))
        lock.unlock()
        guard recent.count >= 3 * Self.sampleRate else { return nil }
        let energy = recent.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (Self.wav(recent), (energy / Double(recent.count)).squareRoot())
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        put(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(sampleRate))
        put(UInt32(sampleRate * 2))
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(byteCount)
        samples.forEach { put($0) }
        return data
    }
}

/// Hands a broadcast extension's match to the app the next time it comes to the foreground.
public enum BroadcastResultMailbox {
    private static let key = "knightmusic.pending_broadcast_track"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: "group.com.knightabdo.knightmusic") }

    public static func post(trackID: String) { defaults?.set(trackID, forKey: key) }

    public static func take() -> String? {
        guard let id = defaults?.string(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        return id
    }
}
