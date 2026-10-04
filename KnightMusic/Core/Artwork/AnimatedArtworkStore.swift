import Foundation
import os

struct AnimatedArtworkRequest: Sendable {
    var albumId: String
    var artist: String?
    var album: String?
    var coverArt: String?
}

/// Disk index + download pipeline for animated artwork. Everything heavy happens here, off the main actor.
/// Files: Caches/AnimatedArtwork/<albumId>-square.mp4 / -tall.mp4, index.json (lookup results incl. misses).
actor AnimatedArtworkStore {
    struct Entry: Codable {
        var found: Bool
        var square: Bool
        var tall: Bool
        var source: String?
        var checkedAt: Date
        var retryAfter: Date?
    }

    static let retryInterval: TimeInterval = 7 * 24 * 3600

    private let directory: URL
    private var index: [String: Entry] = [:]
    private var indexLoaded = false
    private var inflight: [String: Task<AnimatedArtwork?, Never>] = [:]
    private let log = Logger(subsystem: "com.knightabdo.knightmusic", category: "animated-artwork")

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("AnimatedArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Public

    /// Files already on disk; no network, no Wi-Fi requirement.
    func cached(albumId: String) -> AnimatedArtwork? {
        let square = fileURL(albumId, "square"), tall = fileURL(albumId, "tall")
        let hasSquare = FileManager.default.fileExists(atPath: square.path)
        let hasTall = FileManager.default.fileExists(atPath: tall.path)
        if hasSquare { return AnimatedArtwork(squareVideoURL: square, tallVideoURL: hasTall ? tall : nil) }
        if hasTall { return AnimatedArtwork(squareVideoURL: tall, tallVideoURL: tall) } // aspect-fill crops tall to square
        return nil
    }

    /// Produces or returns the sibling .lock.mp4 files for lock-screen playback.
    /// Remuxes without re-encoding (passthrough, fallback to highest quality).
    func ensureLockFiles(albumId: String) async -> (square: URL?, tall: URL?) {
        let squareSrc = fileURL(albumId, "square")
        let tallSrc = fileURL(albumId, "tall")
        let squareLock = lockFileURL(albumId, "square")
        let tallLock = lockFileURL(albumId, "tall")

        var resultSquare: URL?
        var resultTall: URL?

        // Clean up orphaned lock files if source does not exist
        if !FileManager.default.fileExists(atPath: squareSrc.path) {
            try? FileManager.default.removeItem(at: squareLock)
        }
        if !FileManager.default.fileExists(atPath: tallSrc.path) {
            try? FileManager.default.removeItem(at: tallLock)
        }

        if FileManager.default.fileExists(atPath: squareSrc.path) {
            if FileManager.default.fileExists(atPath: squareLock.path) {
                resultSquare = squareLock
            } else {
                do {
                    try await HLSArtwork.remuxForLockScreen(source: squareSrc, destination: squareLock)
                    resultSquare = squareLock
                } catch {
                    // Remux error is logged inside remuxForLockScreen
                }
            }
        }

        if FileManager.default.fileExists(atPath: tallSrc.path) {
            if FileManager.default.fileExists(atPath: tallLock.path) {
                resultTall = tallLock
            } else {
                do {
                    try await HLSArtwork.remuxForLockScreen(source: tallSrc, destination: tallLock)
                    resultTall = tallLock
                } catch {
                    // Remux error is logged inside remuxForLockScreen
                }
            }
        }

        return (resultSquare, resultTall)
    }

    func delete(albumId: String) {
        loadIndexIfNeeded()
        index.removeValue(forKey: albumId)
        saveIndex()
        for variant in ["square", "tall"] {
            try? FileManager.default.removeItem(at: fileURL(albumId, variant))
            try? FileManager.default.removeItem(at: lockFileURL(albumId, variant))
        }
    }

    func resolve(_ request: AnimatedArtworkRequest, allowDownload: Bool) async -> AnimatedArtwork? {
        if let hit = cached(albumId: request.albumId) { return hit }
        loadIndexIfNeeded()
        if let entry = index[request.albumId], !entry.found, let retry = entry.retryAfter, retry > Date() { return nil }
        guard allowDownload else { return nil }
        if let running = inflight[request.albumId] { return await running.value }
        let task = Task { await self.fetch(request) }
        inflight[request.albumId] = task
        let result = await task.value
        inflight[request.albumId] = nil
        return result
    }

    // MARK: Fetch

    private func fetch(_ r: AnimatedArtworkRequest) async -> AnimatedArtwork? {
        var m8Square: URL?, m8Tall: URL?
        var m8Outcome = HLSArtwork.SearchOutcome.miss

        if let artist = r.artist, let album = r.album, !artist.isEmpty, !album.isEmpty {
            let cleaned = HLSArtwork.cleanAlbumName(album)
            for candidate in HLSArtwork.artistCandidates(artist) {
                m8Outcome = await HLSArtwork.search(artist: candidate, album: cleaned)
                if case .miss = m8Outcome { continue }
                break
            }
        }

        switch m8Outcome {
        case .transient:
            log.info("m8tec lookup transient failure for \(r.albumId, privacy: .public)")
            return nil
        case .found(let square, let tall):
            m8Square = square; m8Tall = tall
            let sqDest = fileURL(r.albumId, "square")
            let tlDest = fileURL(r.albumId, "tall")
            async let sq = download(master: m8Square, to: sqDest)
            async let tl = download(master: m8Tall, to: tlDest)
            let (gotSquare, gotTall) = await (sq, tl)
            if !gotSquare {
                try? FileManager.default.removeItem(at: fileURL(r.albumId, "square"))
                try? FileManager.default.removeItem(at: lockFileURL(r.albumId, "square"))
            }
            if !gotTall {
                try? FileManager.default.removeItem(at: fileURL(r.albumId, "tall"))
                try? FileManager.default.removeItem(at: lockFileURL(r.albumId, "tall"))
            }
            if gotSquare || gotTall {
                _ = await ensureLockFiles(albumId: r.albumId)
                record(r.albumId, Entry(found: true, square: gotSquare, tall: gotTall, source: "m8tec", checkedAt: Date(), retryAfter: nil))
                NotificationCenter.default.post(
                    name: .animatedArtworkDidBecomeReady,
                    object: nil,
                    userInfo: ["albumId": r.albumId]
                )
                return cached(albumId: r.albumId)
            }
            return nil // download problem: retry next time instead of caching a miss
        case .miss:
            break
        }

        switch await convertAnimatedCover(r) {
        case .converted:
            try? FileManager.default.removeItem(at: fileURL(r.albumId, "tall"))
            try? FileManager.default.removeItem(at: lockFileURL(r.albumId, "tall"))
            _ = await ensureLockFiles(albumId: r.albumId)
            record(r.albumId, Entry(found: true, square: true, tall: false, source: "cover", checkedAt: Date(), retryAfter: nil))
            NotificationCenter.default.post(
                name: .animatedArtworkDidBecomeReady,
                object: nil,
                userInfo: ["albumId": r.albumId]
            )
            return cached(albumId: r.albumId)
        case .notAnimated:
            delete(albumId: r.albumId)
            record(r.albumId, Entry(found: false, square: false, tall: false, source: nil, checkedAt: Date(),
                                    retryAfter: Date().addingTimeInterval(Self.retryInterval)))
            return nil
        case .failed:
            return nil
        }
    }

    private func download(master: URL?, to destination: URL) async -> Bool {
        guard let master else { return false }
        do {
            try await HLSArtwork.downloadMP4(master: master, to: destination)
            return true
        } catch {
            log.error("animated download failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private enum CoverOutcome { case converted, notAnimated, failed }

    /// Fallback: the album's original cover may itself be an animated WebP/GIF.
    private func convertAnimatedCover(_ r: AnimatedArtworkRequest) async -> CoverOutcome {
        guard let coverArt = r.coverArt, !coverArt.isEmpty,
              let url = ArtworkLoader.shared.coverArtURL(id: coverArt, size: nil) else { return .failed }
        do {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return .failed }
            guard AnimatedImageConverter.isAnimated(data) else { return .notAnimated }
            let part = directory.appendingPathComponent(UUID().uuidString + ".part.mp4")
            guard try await AnimatedImageConverter.convert(data: data, to: part) else { return .notAnimated }
            let destination = fileURL(r.albumId, "square")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: lockFileURL(r.albumId, "square"))
            try FileManager.default.moveItem(at: part, to: destination)
            return .converted
        } catch {
            log.error("cover conversion failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    // MARK: Index persistence

    private func fileURL(_ albumId: String, _ variant: String) -> URL {
        let safe = safeAlbumId(albumId)
        return directory.appendingPathComponent("\(safe)-\(variant).mp4")
    }

    private func lockFileURL(_ albumId: String, _ variant: String) -> URL {
        let safe = safeAlbumId(albumId)
        return directory.appendingPathComponent("\(safe)-\(variant).lock.mp4")
    }

    private func safeAlbumId(_ albumId: String) -> String {
        String(albumId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let data = try? Data(contentsOf: indexURL) else { return }
        index = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func record(_ albumId: String, _ entry: Entry) {
        loadIndexIfNeeded()
        index[albumId] = entry
        saveIndex()
    }

    private func saveIndex() {
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            log.error("index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
