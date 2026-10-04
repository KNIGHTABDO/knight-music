import Foundation
import UIKit
import GRDB

/// Persistent watch metadata stored in UserDefaults so unfinished watches can resume across relaunch/foreground.
struct PendingArrivalWatch: Codable, Sendable {
    let conversationId: String
    let messageId: String
    let tracks: [AddedTrack]
    let startedAt: Date
}

/// Watches for newly imported songs on the Navidrome server and local database.
@MainActor
final class ArrivalWatcher {
    static let shared = ArrivalWatcher()

    private let userDefaultsKey = "knight_pending_arrival_watches"
    private var activeTasks: [String: Task<Void, Never>] = [:]

    weak var app: AppModel?
    weak var library: LibraryRepository?
    weak var artwork: AnimatedArtworkService?
    weak var ui: UIState?
    weak var hermes: HermesService?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumePendingWatches()
            }
        }
    }

    // MARK: - Normalization & Matching

    /// Normalizes a string for matching: lowercase, strip diacritics, remove "(feat. …)", "[…]", "(…)",
    /// punctuation, quotes, and extra whitespace.
    static func normalize(_ string: String) -> String {
        var text = string.lowercased()
        text = text.folding(options: .diacriticInsensitive, locale: .current)

        // Remove bracketed content: [...]
        if let bracketRegex = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = bracketRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }

        // Remove parenthetical content: (...)
        if let parenRegex = try? NSRegularExpression(pattern: "\\([^\\)]*\\)", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = parenRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }

        // Remove unparenthesized feature credits: feat., ft., featuring
        if let featRegex = try? NSRegularExpression(pattern: "\\b(?:feat|ft|featuring)\\b\\.?[^,;]*", options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..., in: text)
            text = featRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }

        // Strip quotes and apostrophes completely
        for quote in ["'", "\"", "’", "‘", "“", "”", "`"] {
            text = text.replacingOccurrences(of: quote, with: "")
        }

        // Replace any remaining punctuation/symbols with a space
        var cleaned = ""
        for char in text {
            if char.isLetter || char.isNumber {
                cleaned.append(char)
            } else {
                cleaned.append(" ")
            }
        }

        // Collapse extra spaces and trim
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// Extracts artist tokens from an artist string.
    /// Handles multiple artists separated by "/", ",", ";", "&", "+", or feature credits.
    static func extractArtistTokens(_ artist: String) -> [String] {
        let raw = artist.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let separatorPattern = "[,;/&+]|\\b(?:feat\\.?|ft\\.?|featuring|vs\\.?|with|and)\\b"

        var tokens: [String] = []
        let fullNormalized = normalize(artist)
        if !fullNormalized.isEmpty {
            tokens.append(fullNormalized)
        }

        guard let regex = try? NSRegularExpression(pattern: separatorPattern, options: [.caseInsensitive]) else {
            return tokens
        }

        let range = NSRange(raw.startIndex..., in: raw)
        let replaced = regex.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "|||")
        let parts = replaced.components(separatedBy: "|||")

        for part in parts {
            let n = normalize(part)
            if !n.isEmpty && !tokens.contains(n) {
                tokens.append(n)
            }
        }
        return tokens
    }

    /// Checks if any artist token matches between track artist and song artist.
    static func artistOverlaps(trackArtist: String, songArtist: String) -> Bool {
        let trackTokens = extractArtistTokens(trackArtist)
        let songTokens = extractArtistTokens(songArtist)
        guard !trackTokens.isEmpty, !songTokens.isEmpty else { return false }

        for t in trackTokens {
            for s in songTokens {
                if t == s {
                    return true
                }
                if min(t.count, s.count) >= 3 && (t.contains(s) || s.contains(t)) {
                    return true
                }
            }
        }
        return false
    }

    /// Matches an AddedTrack against a Song from the local database or server.
    /// Title must match (equal after normalization, or one contains the other)
    /// AND artist overlaps (any artist token match).
    static func matches(track: AddedTrack, song: Song) -> Bool {
        let tTitle = normalize(track.title)
        let sTitle = normalize(song.title)
        guard !tTitle.isEmpty, !sTitle.isEmpty else { return false }

        let titleMatches = (tTitle == sTitle) || tTitle.contains(sTitle) || sTitle.contains(tTitle)
        guard titleMatches else { return false }

        guard let songArtist = song.artist, !songArtist.isEmpty else { return false }
        return artistOverlaps(trackArtist: track.artist, songArtist: songArtist)
    }

    // MARK: - Persistence (UserDefaults JSON)

    private func loadPendingWatches() -> [PendingArrivalWatch] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PendingArrivalWatch].self, from: data)) ?? []
    }

    private func savePendingWatches(_ watches: [PendingArrivalWatch]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(watches) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func addPendingWatch(_ watch: PendingArrivalWatch) {
        var watches = loadPendingWatches().filter { $0.messageId != watch.messageId }
        watches.append(watch)
        savePendingWatches(watches)
    }

    private func removePendingWatch(messageId: String) {
        let watches = loadPendingWatches().filter { $0.messageId != messageId }
        savePendingWatches(watches)
    }

    // MARK: - Watch Execution

    func watch(
        conversationId: String,
        messageId: String,
        tracks: [AddedTrack],
        app: AppModel,
        library: LibraryRepository,
        artwork: AnimatedArtworkService,
        ui: UIState?,
        hermes: HermesService,
        startedAt: Date? = nil
    ) {
        self.app = app
        self.library = library
        self.artwork = artwork
        if let ui { self.ui = ui }
        self.hermes = hermes

        let watchStart = startedAt ?? Date()

        // Cancel any existing task for this message
        activeTasks[messageId]?.cancel()

        // Persist pending watch in UserDefaults
        addPendingWatch(PendingArrivalWatch(
            conversationId: conversationId,
            messageId: messageId,
            tracks: tracks,
            startedAt: watchStart
        ))

        hermes.importStatus[messageId] = "Importing to library…"

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performWatch(
                conversationId: conversationId,
                messageId: messageId,
                tracks: tracks,
                watchStart: watchStart,
                app: app,
                library: library,
                artwork: artwork,
                ui: ui,
                hermes: hermes
            )
        }
        activeTasks[messageId] = task
    }

    private func performWatch(
        conversationId: String,
        messageId: String,
        tracks: [AddedTrack],
        watchStart: Date,
        app: AppModel,
        library: LibraryRepository,
        artwork: AnimatedArtworkService,
        ui: UIState?,
        hermes: HermesService
    ) async {
        Log.sync.info("ArrivalWatcher [\(messageId)]: Starting arrival watch for \(tracks.count) track(s)")

        var remainingTracks = tracks
        if let alreadyMatched = hermes.matchedSongs[messageId] {
            remainingTracks.removeAll { track in
                alreadyMatched.contains { song in Self.matches(track: track, song: song) }
            }
        }

        if remainingTracks.isEmpty {
            Log.sync.info("ArrivalWatcher [\(messageId)]: All tracks already matched")
            hermes.importStatus[messageId] = nil
            removePendingWatch(messageId: messageId)
            activeTasks[messageId] = nil
            return
        }

        // 1. Ask Navidrome for a quick scan: try await client.startScan(fullScan: false)
        if let client = app.client {
            Log.sync.info("ArrivalWatcher [\(messageId)]: Requesting quick scan from Navidrome...")
            do {
                let scanStatus = try await client.startScan(fullScan: false)
                Log.sync.info("ArrivalWatcher [\(messageId)]: startScan triggered, scanning: \(scanStatus.scanning)")
            } catch {
                Log.sync.warning("ArrivalWatcher [\(messageId)]: startScan request failed: \(error.localizedDescription)")
            }

            // Poll getScanStatus() every 2s until scanning == false (max 120s)
            Log.sync.info("ArrivalWatcher [\(messageId)]: Polling Navidrome getScanStatus() every 2s (max 120s)...")
            let scanDeadline = Date().addingTimeInterval(120)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while Date() < scanDeadline {
                if Task.isCancelled {
                    Log.sync.info("ArrivalWatcher [\(messageId)]: Cancelled during scan polling")
                    return
                }
                do {
                    let status = try await client.getScanStatus()
                    Log.sync.debug("ArrivalWatcher [\(messageId)]: Scan status scanning=\(status.scanning), count=\(status.count ?? 0)")
                    if !status.scanning {
                        Log.sync.info("ArrivalWatcher [\(messageId)]: Navidrome scan finished")
                        break
                    }
                } catch {
                    Log.sync.warning("ArrivalWatcher [\(messageId)]: getScanStatus failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        } else {
            Log.sync.warning("ArrivalWatcher [\(messageId)]: No SubsonicClient available for startScan")
        }

        if Task.isCancelled { return }

        // 4. Retry steps 2–3 every 5s up to 3 minutes total
        let totalTimeout: TimeInterval = 180
        while Date().timeIntervalSince(watchStart) < totalTimeout {
            if Task.isCancelled { return }

            // Step 2: await app.refresh(force: true) so local DB definitely re-reads library
            Log.sync.info("ArrivalWatcher [\(messageId)]: Running app.refresh(force: true)...")
            let refreshResult = await app.refresh(force: true)
            Log.sync.info("ArrivalWatcher [\(messageId)]: app.refresh(force: true) completed: \(refreshResult)")

            if Task.isCancelled { return }

            // Step 3: Match each remaining AddedTrack against local DB with normalization
            for track in remainingTracks {
                if Task.isCancelled { return }
                Log.sync.info("ArrivalWatcher [\(messageId)]: Matching track '\(track.title)' by '\(track.artist)' in local DB...")

                var matchedSong: Song?
                if let database = library.database {
                    matchedSong = await searchDatabase(database: database, for: track)
                }

                // If no DB match, ask the server client.search3(query: <title>, songCount: 10, ...)
                if matchedSong == nil, let client = app.client {
                    Log.sync.info("ArrivalWatcher [\(messageId)]: No local DB match for '\(track.title)'. Searching server search3...")
                    do {
                        let searchResult = try await client.search3(query: track.title, songCount: 10)
                        let serverSongs = searchResult.songs
                        Log.sync.info("ArrivalWatcher [\(messageId)]: Server search3 returned \(serverSongs.count) song(s)")

                        if let serverMatch = serverSongs.first(where: { Self.matches(track: track, song: $0) }) {
                            Log.sync.info("ArrivalWatcher [\(messageId)]: Found on server: '\(serverMatch.title)' (\(serverMatch.id)). DB lacks it. Performing forced refresh...")
                            let forceOk = await app.refresh(force: true)
                            Log.sync.info("ArrivalWatcher [\(messageId)]: Forced refresh completed: \(forceOk). Re-matching in DB...")
                            if let database = library.database {
                                matchedSong = await searchDatabase(database: database, for: track, specificId: serverMatch.id)
                            }
                        }
                    } catch {
                        Log.sync.warning("ArrivalWatcher [\(messageId)]: Server search3 failed: \(error.localizedDescription)")
                    }
                }

                if let song = matchedSong {
                    Log.sync.info("ArrivalWatcher [\(messageId)]: Matched '\(song.title)' (\(song.id)) successfully")
                    remainingTracks.removeAll(where: { $0.id == track.id })

                    hermes.appendMatchedSong(conversationId: conversationId, messageId: messageId, song: song)
                    ui?.showToast("Added \(song.title) to your library")
                    artwork.prefetch(for: [song])
                }
            }

            if remainingTracks.isEmpty {
                Log.sync.info("ArrivalWatcher [\(messageId)]: All tracks matched successfully")
                hermes.importStatus[messageId] = nil
                removePendingWatch(messageId: messageId)
                activeTasks[messageId] = nil
                return
            }

            Log.sync.info("ArrivalWatcher [\(messageId)]: \(remainingTracks.count) track(s) remaining. Sleeping 5s before next retry...")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        // Timeout reached (3 minutes total)
        if !remainingTracks.isEmpty {
            Log.sync.warning("ArrivalWatcher [\(messageId)]: Timed out after 3 minutes with \(remainingTracks.count) track(s) missing")
            hermes.importStatus[messageId] = "Not found yet"
            removePendingWatch(messageId: messageId)
            activeTasks[messageId] = nil
        }
    }

    private func searchDatabase(database: LibraryDatabase, for track: AddedTrack, specificId: String? = nil) async -> Song? {
        let cleanTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? await database.pool.read { db in
            // 1. If specific ID provided, check that first
            if let specificId, let song = try Song.fetchOne(db, sql: "SELECT * FROM song WHERE id = ?", arguments: [specificId]) {
                if Self.matches(track: track, song: song) {
                    return song
                }
            }

            var candidates: [Song] = []

            // 2. Search via FTS5 / LibraryQueries
            if let searchResults = try? LibraryQueries.search(db, text: cleanTitle, limit: 30) {
                candidates.append(contentsOf: searchResults.songs)
            }

            // 3. Search recently added songs
            if let recent = try? Song.fetchAll(db, sql: "SELECT * FROM song ORDER BY created DESC LIMIT 50") {
                candidates.append(contentsOf: recent)
            }

            // 4. Fallback LIKE search on title
            let like = LibraryQueries.likePattern(cleanTitle)
            if let byLike = try? Song.fetchAll(db, sql: "SELECT * FROM song WHERE title LIKE ? ESCAPE '\\' LIMIT 30", arguments: [like]) {
                candidates.append(contentsOf: byLike)
            }

            // Deduplicate and test matches
            var seen = Set<String>()
            for song in candidates {
                if seen.insert(song.id).inserted {
                    if Self.matches(track: track, song: song) {
                        return song
                    }
                }
            }
            return nil
        }) ?? nil
    }

    // MARK: - Resume Unfinished Watches

    func resumePendingWatches() {
        let pending = loadPendingWatches()
        guard !pending.isEmpty else { return }

        Log.sync.info("ArrivalWatcher: Checking \(pending.count) pending watch(es)...")

        let app = self.app ?? AppModel.shared
        guard let app else {
            Log.sync.warning("ArrivalWatcher: Cannot resume watches: AppModel not available yet")
            return
        }
        let library = self.library ?? app.library
        let artwork = self.artwork ?? app.artwork
        let hermes = self.hermes ?? app.hermes
        let ui = self.ui

        for watchItem in pending {
            if activeTasks[watchItem.messageId] != nil {
                continue
            }

            if Date().timeIntervalSince(watchItem.startedAt) >= 180 {
                Log.sync.info("ArrivalWatcher: Watch for message \(watchItem.messageId) timed out while inactive")
                hermes.importStatus[watchItem.messageId] = "Not found yet"
                removePendingWatch(messageId: watchItem.messageId)
                continue
            }

            Log.sync.info("ArrivalWatcher: Resuming pending watch for message \(watchItem.messageId)")
            watch(
                conversationId: watchItem.conversationId,
                messageId: watchItem.messageId,
                tracks: watchItem.tracks,
                app: app,
                library: library,
                artwork: artwork,
                ui: ui,
                hermes: hermes,
                startedAt: watchItem.startedAt
            )
        }
    }
}
