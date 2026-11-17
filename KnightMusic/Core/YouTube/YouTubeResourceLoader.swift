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
            guard length > 0 else { throw YouTubeError.invalidResponse }
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
            let requestedLength = Int64(dataRequest.requestedLength)
            guard offset >= 0, dataRequest.requestedOffset >= 0, requestedLength >= 0 else {
                throw YouTubeError.invalidResponse
            }
            if offset == length || (requestedLength == 0 && !dataRequest.requestsAllDataToEndOfResource) {
                request.finishLoading()
                return
            }
            guard offset >= dataRequest.requestedOffset, offset < length else { throw YouTubeError.invalidResponse }
            let end: Int64
            if dataRequest.requestsAllDataToEndOfResource {
                end = length - 1
            } else {
                let (requestedEnd, overflow) = dataRequest.requestedOffset.addingReportingOverflow(requestedLength - 1)
                guard !overflow else { throw YouTubeError.invalidResponse }
                end = min(length - 1, requestedEnd)
            }
            guard offset <= end else { throw YouTubeError.invalidResponse }
            var renewed = false
            var entityTag: String?
            // Small first read so playback starts quickly; then the stream's full chunk size.
            var chunk: Int64 = min(256 << 10, stream.chunkSize)
            while offset <= end {
                try Task.checkCancellation()
                guard chunk > 0 else { throw YouTubeError.invalidResponse }
                let upper = offset + min(chunk, end - offset + 1) - 1
                let (bytes, response) = try await session.bytes(for: stream.request(range: offset...upper))
                guard let http = response as? HTTPURLResponse else {
                    bytes.task.cancel()
                    throw YouTubeError.invalidResponse
                }
                let status = http.statusCode
                if status == 403 || status == 410 || status == 404, !renewed {
                    // The URL expired or was revoked: mint a new one and continue from the same offset.
                    bytes.task.cancel()
                    renewed = true
                    await YouTubeMusic.shared.invalidate(videoId: videoId)
                    let replacement = try await YouTubeMusic.shared.stream(videoId: videoId)
                    guard Self.sameRepresentation(stream, replacement) else {
                        throw YouTubeError.representationChanged
                    }
                    stream = replacement
                    continue
                }
                if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"),
                   encoding.lowercased() != "identity" {
                    bytes.task.cancel()
                    throw YouTubeError.invalidResponse
                }
                if http.mimeType?.lowercased().hasPrefix("text/") == true {
                    bytes.task.cancel()
                    throw YouTubeError.invalidResponse
                }
                let piece: Data
                if status == 206 {
                    let responseTag = http.value(forHTTPHeaderField: "ETag")
                    if let entityTag, responseTag != entityTag {
                        bytes.task.cancel()
                        throw YouTubeError.representationChanged
                    }
                    if entityTag == nil { entityTag = responseTag }
                    guard let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                          range.0 == offset, range.1 == upper, range.2 == length,
                          http.expectedContentLength < 0 || http.expectedContentLength == upper - offset + 1 else {
                        bytes.task.cancel()
                        throw YouTubeError.invalidResponse
                    }
                    let expectedBytes = upper - offset + 1
                    let maxRangeResponseBytes: Int64 = 16 << 20
                    guard expectedBytes > 0, expectedBytes <= maxRangeResponseBytes else {
                        bytes.task.cancel()
                        throw YouTubeError.invalidResponse
                    }
                    var data = Data()
                    data.reserveCapacity(Int(expectedBytes))
                    for try await byte in bytes {
                        guard Int64(data.count) < expectedBytes else {
                            bytes.task.cancel()
                            throw YouTubeError.invalidResponse
                        }
                        data.append(byte)
                    }
                    guard Int64(data.count) == expectedBytes else { throw YouTubeError.invalidResponse }
                    piece = data
                } else if status == 200 {
                    // Supported AutoMix /yt/audio responses honor Range and return 206. Cancel
                    // before reading the body: ignored Range must not buffer a whole song here.
                    bytes.task.cancel()
                    throw YouTubeError.unsupportedRangeResponse
                } else {
                    bytes.task.cancel()
                    throw YouTubeError.http(status)
                }
                try Task.checkCancellation()
                dataRequest.respond(with: piece)
                offset += Int64(piece.count)
                chunk = stream.chunkSize
            }
            request.finishLoading()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            Log.playback.warning("YouTube \(videoId) loading failed: \(error.localizedDescription)")
            request.finishLoading(with: error)
        }
    }

    /// Strict single-range parser: bytes start-end/total. Wildcard and malformed totals are not
    /// useful for joining a known YouTube representation, so reject them.
    private static func contentRange(_ value: String?) -> (Int64, Int64, Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }

    /// Keep a renewed URL on the same byte-addressable representation. Signed URL fields and
    /// regional hosts may rotate, but the selected player client, length and format identity may not.
    private static func sameRepresentation(_ old: YTStream, _ new: YTStream) -> Bool {
        guard old.client == new.client, old.contentLength == new.contentLength else { return false }
        if old.client == "server" && (old.url.host != new.url.host || old.url.path != new.url.path) {
            return false
        }
        let oldItems = URLComponents(url: old.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let newItems = URLComponents(url: new.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for key in ["itag", "mime", "clen"] {
            let oldValue = oldItems.first { $0.name == key }?.value
            let newValue = newItems.first { $0.name == key }?.value
            if oldValue != newValue { return false }
        }
        return true
    }

    /// Size of a stream that did not report one (the AutoMix server fallback): "Content-Range: bytes 0-1/<size>".
    private static func probeLength(_ stream: YTStream, session: URLSession) async throws -> Int64 {
        let (bytes, response) = try await session.bytes(for: stream.request(range: 0...1))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw YouTubeError.invalidResponse }
        if http.statusCode == 200 { throw YouTubeError.unsupportedRangeResponse }
        guard http.statusCode == 206 else { throw YouTubeError.http(http.statusCode) }
        guard let range = contentRange(http.value(forHTTPHeaderField: "Content-Range")),
              range.0 == 0, range.1 == min(1, range.2 - 1) else { throw YouTubeError.invalidResponse }
        return range.2
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
