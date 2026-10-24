import AVFoundation
import Foundation

/// Plays `kmyt://<videoId>/audio.m4a` URLs. Resolving a YouTube stream takes network calls, and its media
/// servers want the minting client's user agent and bounded ranges, so AVPlayer reads through this loader
/// instead of fetching a googlevideo URL itself. A URL that expires or gets blocked mid-song is re-minted.
final class YouTubeResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = YouTubeResourceLoader()
    static let scheme = "kmyt"

    let queue = DispatchQueue(label: "com.knightabdo.knightmusic.youtube-loader")
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private override init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    static func url(videoId: String) -> URL? { URL(string: "\(scheme)://\(videoId)/audio.m4a") }

    static func videoId(in url: URL) -> String? { url.scheme == scheme ? url.host : nil }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let videoId = Self.videoId(in: url) else { return false }
        let key = ObjectIdentifier(loadingRequest)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.serve(loadingRequest, videoId: videoId)
            self?.finished(key)
        }
        lock.lock()
        tasks[key] = task
        lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    private func finished(_ key: ObjectIdentifier) {
        lock.lock()
        tasks[key] = nil
        lock.unlock()
    }

    private func serve(_ request: AVAssetResourceLoadingRequest, videoId: String) async {
        do {
            var stream = try await YouTubeMusic.shared.stream(videoId: videoId)
            let length: Int64
            if let known = stream.contentLength {
                length = known
            } else {
                length = try await Self.probeLength(stream, session: session)
            }
            if let info = request.contentInformationRequest {
                info.contentType = AVFileType.m4a.rawValue
                info.contentLength = length
                info.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return
            }
            var offset = dataRequest.currentOffset
            let end = dataRequest.requestsAllDataToEndOfResource
                ? length - 1
                : min(length - 1, dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1)
            var renewed = false
            // Small first read so playback starts quickly; then the stream's full chunk size.
            var chunk: Int64 = min(256 << 10, stream.chunkSize)
            while offset <= end {
                try Task.checkCancellation()
                let upper = min(end, offset + chunk - 1)
                let (data, response) = try await session.data(for: stream.request(range: offset...upper))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 403 || status == 410 || status == 404, !renewed {
                    // The URL expired or was revoked: mint a new one and continue from the same offset.
                    renewed = true
                    await YouTubeMusic.shared.invalidate(videoId: videoId)
                    stream = try await YouTubeMusic.shared.stream(videoId: videoId)
                    continue
                }
                guard status == 206 || status == 200, !data.isEmpty else { throw YouTubeError.http(status) }
                // A server ignoring Range sends the whole file from byte 0.
                let piece = status == 200 && offset > 0
                    ? data.subdata(in: Int(min(offset, Int64(data.count)))..<min(data.count, Int(upper + 1)))
                    : data.prefix(Int(upper - offset + 1))
                try Task.checkCancellation()
                dataRequest.respond(with: piece)
                offset += Int64(piece.count)
                chunk = stream.chunkSize
                if piece.isEmpty { break }
            }
            request.finishLoading()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            Log.playback.warning("YouTube \(videoId) loading failed: \(error.localizedDescription)")
            request.finishLoading(with: error)
        }
    }

    /// Size of a stream that did not report one (the AutoMix server fallback): "Content-Range: bytes 0-1/<size>".
    private static func probeLength(_ stream: YTStream, session: URLSession) async throws -> Int64 {
        let (_, response) = try await session.data(for: stream.request(range: 0...1))
        guard let http = response as? HTTPURLResponse else { throw YouTubeError.invalidResponse }
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last,
           let size = Int64(total) {
            return size
        }
        if http.statusCode == 200, http.expectedContentLength > 0 { return http.expectedContentLength }
        throw YouTubeError.http(http.statusCode)
    }
}

/// Whole-file download of a YouTube song for the stream cache: parallel ranged chunks into a temp file.
enum YouTubeAudioDownloader {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    static func download(videoId: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yt-\(videoId)-\(UUID().uuidString).m4a")
        do {
            try await fetch(videoId: videoId, to: tmp, progress: progress)
            return tmp
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func fetch(videoId: String, to tmp: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let stream = try await YouTubeMusic.shared.stream(videoId: videoId)
        guard let length = stream.contentLength, length > 0 else {
            // The server fallback serves a finished file in one response.
            let (file, response) = try await session.download(for: stream.request(range: nil))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw YouTubeError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            try FileManager.default.moveItem(at: file, to: tmp)
            return
        }
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        var ranges: [ClosedRange<Int64>] = []
        var start: Int64 = 0
        while start < length {
            ranges.append(start...min(length - 1, start + stream.chunkSize - 1))
            start += stream.chunkSize
        }
        var written: Int64 = 0
        try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
            var pending = ranges[...]
            func add() {
                guard let range = pending.popFirst() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    let (data, response) = try await session.data(for: stream.request(range: range))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 206, data.count == Int(range.upperBound - range.lowerBound + 1) else {
                        if status == 403 { await YouTubeMusic.shared.invalidate(videoId: videoId) }
                        throw YouTubeError.http(status)
                    }
                    return (range.lowerBound, data)
                }
            }
            for _ in 0..<4 { add() }
            while let (offset, data) = try await group.next() {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                progress(Double(written) / Double(length))
                add()
            }
        }
    }
}
