import Foundation
import GRDB
import SwiftUI

/// Adds YouTube Music songs to Navidrome through Knight (the Hermes agent), so they arrive tagged, with art and
/// in the right folder like every other song. Checks the library for copies first and asks before duplicating.
@MainActor @Observable
final class NavidromeImportCenter {
    static let shared = NavidromeImportCenter()

    struct Job: Identifiable, Equatable {
        enum State: Equatable { case waiting, working, importing, done, failed(String) }

        let id = UUID()
        let song: Song
        let force: Bool
        let accountId: UUID
        let existingSongIds: Set<String>
        var conversationId: String?
        var importedSong: Song?
        var state: State = .waiting
        var stage = "Waiting…"

        var isFinished: Bool {
            switch state {
            case .done, .failed: true
            default: false
            }
        }
    }

    /// A song that already looks like it's in the library; the shell asks what to do.
    struct Confirmation: Identifiable {
        enum Kind { case same, similar }

        let id = UUID()
        let song: Song
        let matches: [Song]
        let kind: Kind
        let accountId: UUID
    }

    private(set) var jobs: [Job] = []
    var confirmation: Confirmation?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private weak var ui: UIState?
    @ObservationIgnored private var runner: Task<Void, Never>?

    /// The job the progress pill shows: the running one, else the latest finished one.
    var visibleJob: Job? { jobs.first { !$0.isFinished } ?? jobs.last }

    func isBusy(_ song: Song) -> Bool {
        jobs.contains { $0.song.id == song.id && !$0.isFinished }
    }

    func add(_ song: Song, app: AppModel, ui: UIState) {
        guard song.isYouTube, let accountId = app.activeAccount?.id else {
            ui.showToast("Sign in to your server to add this song.")
            return
        }
        if self.app !== app {
            app.addSessionObserver(fireImmediately: false) { [weak self] app in
                self?.sessionChanged(app)
            }
        }
        self.app = app
        self.ui = ui
        guard !isBusy(song) else {
            ui.showToast("\u{201C}\(song.title)\u{201D} is already being added")
            return
        }
        Haptics.impact(.light)
        let matches = existingCopies(of: song, in: app)
        if !matches.isEmpty {
            let sameVersion = matches.contains { Self.versionTags($0.title) == Self.versionTags(song.title) }
            confirmation = Confirmation(song: song, matches: matches, kind: sameVersion ? .same : .similar, accountId: accountId)
            return
        }
        enqueue(song, force: false)
    }

    func resolve(_ confirmation: Confirmation, addAnyway: Bool) {
        self.confirmation = nil
        guard app?.activeAccount?.id == confirmation.accountId else {
            ui?.showToast("The server changed. Add the song again on the intended server.")
            return
        }
        if addAnyway {
            enqueue(confirmation.song, force: true)
        } else {
            ui?.showToast("Kept the copy you already have")
        }
    }

    func dismissFinished() {
        jobs.removeAll { $0.isFinished }
    }

    // MARK: - Queue

    private func enqueue(_ song: Song, force: Bool) {
        guard let app, let accountId = app.activeAccount?.id, let database = app.database else { return }
        do {
            let ids = try database.pool.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM song")) }
            withAnimation(.smooth) {
                jobs.append(Job(song: song, force: force, accountId: accountId, existingSongIds: ids))
            }
        } catch {
            Log.database.error("Couldn't prepare import: \(error.localizedDescription)")
            ui?.showToast("Couldn't read your library. Try adding the song again.")
            return
        }
        ui?.showToast("Adding \u{201C}\(song.title)\u{201D}…")
        startRunnerIfNeeded()
    }

    private func startRunnerIfNeeded() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            await drain()
            runner = nil
            if jobs.contains(where: { $0.state == .waiting }) { startRunnerIfNeeded() }
        }
    }

    private func sessionChanged(_ app: AppModel) {
        if confirmation?.accountId != app.activeAccount?.id { confirmation = nil }
        let outdated = jobs.filter { !$0.isFinished && $0.accountId != app.activeAccount?.id }
        guard !outdated.isEmpty else { return }
        runner?.cancel()
        for job in outdated {
            update(job.id) {
                $0.state = .failed("The server changed. Add the song again on the intended server.")
                $0.stage = "Stopped after switching servers"
            }
        }
    }

    private func drain() async {
        while !Task.isCancelled {
            while !Task.isCancelled, let index = jobs.firstIndex(where: { $0.state == .waiting }) {
                await run(jobs[index].id)
            }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if !jobs.contains(where: { $0.state == .waiting }) {
                withAnimation(.smooth) { dismissFinished() }
                return
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.smooth) { change(&jobs[index]) }
    }

    private func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    private func run(_ id: UUID) async {
        guard let app, let ui, let job = job(id), let client = app.client else { return }
        guard app.activeAccount?.id == job.accountId, !Task.isCancelled else { return }
        let song = job.song
        let hermes = app.hermes

        guard hermes.settings.isConfigured else {
            update(id) { $0.state = .working; $0.stage = "Downloading on the server…" }
            switch await YouTubeImporter.add(song, client: client) {
            case .downloaded(let path):
                await confirmArrival(id, expectedPath: path)
            case .failed(let message): finish(id, .failed(message))
            }
            return
        }

        // Knight runs one conversation at a time; never cut off one the user started.
        update(id) { $0.stage = "Waiting for Knight…" }
        let waitDeadline = Date().addingTimeInterval(600)
        while hermes.isRunning {
            try? await Task.sleep(for: .seconds(1))
            guard isCurrent(id) else { return }
            if Date() >= waitDeadline { return finish(id, .failed("Knight is still busy. Try adding this song again later.")) }
        }
        guard isCurrent(id) else { return }

        let conversationId = "km-\(UUID().uuidString.lowercased())"
        update(id) { $0.conversationId = conversationId; $0.state = .working; $0.stage = "Knight is on it…" }
        hermes.sendMessage(conversationId: conversationId, text: prompt(for: song, force: job.force),
                           app: app, library: app.library, artwork: app.artwork, ui: ui)

        var sawRun = false
        let started = Date()
        var lastRecovery = Date()
        while true {
            try? await Task.sleep(for: .seconds(1))
            guard isCurrent(id) else { return }
            if Date().timeIntervalSince(started) >= 600 {
                return finish(id, .failed("Knight hasn't confirmed the download yet. Open Knight to check its progress."))
            }
            let active = hermes.isRunning && hermes.activeConversationId == conversationId
            if active {
                sawRun = true
                if let step = hermes.activeToolSteps.last {
                    update(id) { $0.stage = step.label }
                }
                continue
            }
            let reply = hermes.store.conversation(for: conversationId)?.messages.last(where: { $0.role == .assistant })
            guard let reply else {
                if !sawRun && Date().timeIntervalSince(started) < 30 { continue }
                return finish(id, .failed("Knight didn't answer"))
            }
            // The app was in the background: the run may have finished on the server without us hearing it.
            if reply.status == "running" {
                update(id) { $0.stage = "Checking with Knight…" }
                if Date().timeIntervalSince(lastRecovery) > 4 {
                    lastRecovery = Date()
                    await hermes.recoverRunningMessages()
                }
                continue
            }

            if reply.status == "failed" || reply.status == "stopped" {
                return finish(id, .failed("Knight couldn't finish the import"))
            }
            await confirmArrival(id)
            return
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard !Task.isCancelled, let job = job(id), !job.isFinished else { return false }
        return app?.activeAccount?.id == job.accountId
    }

    private func confirmArrival(_ id: UUID, expectedPath: String? = nil) async {
        guard isCurrent(id), let app, let job = job(id), let database = app.database else { return }
        update(id) { $0.state = .importing; $0.stage = "Scanning your library…" }
        do {
            try await app.client?.startScan(fullScan: false)
        } catch {
            Log.sync.warning("Import scan request failed: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(180)
        var attempt = 0
        while isCurrent(id), Date() < deadline {
            // A full pass also covers servers whose scan token doesn't change. Other polls use incremental sync.
            await app.refresh(force: attempt % 6 == 0)
            guard isCurrent(id) else { return }
            do {
                if let song = try await ImportedSongMatcher.find(job.song, in: database,
                                                               excluding: job.existingSongIds, expectedPath: expectedPath) {
                    guard isCurrent(id) else { return }
                    update(id) { $0.importedSong = song }
                    app.artwork.prefetch(for: [song])
                    finish(id, .done)
                    return
                }
            } catch {
                Log.database.warning("Confirming import failed: \(error.localizedDescription)")
            }
            update(id) { $0.stage = "Waiting for the song to appear…" }
            attempt += 1
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
        guard isCurrent(id) else { return }
        finish(id, .failed("The song hasn't appeared in your library yet. Check Navidrome's scan and try again."))
    }

    private func finish(_ id: UUID, _ state: Job.State) {
        guard isCurrent(id), let job = job(id) else { return }
        if case .done = state, job.importedSong == nil { return }
        let title = job.song.title
        update(id) {
            $0.state = state
            if case .done = state { $0.stage = "Added to your library" }
            if case .failed(let message) = state { $0.stage = message }
        }
        switch state {
        case .done:
            Haptics.success()
            ui?.showToast("\u{201C}\(title)\u{201D} is in your library")
        case .failed(let message):
            Haptics.error()
            Log.api.warning("Navidrome import of \(title) failed: \(message)")
            ui?.showToast(message)
        default:
            break
        }
    }

    private func prompt(for song: Song, force: Bool) -> String {
        var lines = ["Add this exact song from YouTube Music to my Navidrome library, the same way you add any other song: proper tags, cover art, album and folder."]
        if let videoId = song.youTubeVideoId {
            lines.append("Link: https://music.youtube.com/watch?v=\(videoId)")
        }
        lines.append("Title: \(song.title)")
        if let artist = song.artist, !artist.isEmpty { lines.append("Artist: \(artist)") }
        if let album = song.album, !album.isEmpty { lines.append("Album: \(album)") }
        if let year = song.year { lines.append("Year: \(year)") }
        lines.append("Use this version exactly (keep slowed/reverb/remix/live etc. if the title says so); don't swap it for another release.")
        if force {
            lines.append("I already have a similar song in the library and I want this one too. Add it as a separate song; don't replace or delete anything.")
        } else {
            lines.append("Don't replace or delete anything that's already there.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Duplicate detection

    /// Library songs with the same base title (version tags and brackets stripped) and an overlapping artist.
    private func existingCopies(of song: Song, in app: AppModel) -> [Song] {
        let base = ArrivalWatcher.normalize(Self.stripVersionWords(song.title))
        guard !base.isEmpty, let database = app.database else { return [] }
        let artist = song.artist ?? ""
        let candidates = (try? database.pool.read { try LibraryQueries.search($0, text: base, limit: 50) })?.songs ?? []
        return candidates.filter { candidate in
            guard !candidate.isYouTube,
                  ArrivalWatcher.normalize(Self.stripVersionWords(candidate.title)) == base else { return false }
            guard !artist.isEmpty, let other = candidate.artist, !other.isEmpty else { return artist.isEmpty }
            return ArrivalWatcher.artistOverlaps(trackArtist: artist, songArtist: other)
        }
    }

    private nonisolated static let versionWords = [
        "slowed", "reverb", "sped up", "speed up", "nightcore", "remix", "live", "acoustic", "instrumental",
        "remaster", "remastered", "extended", "radio edit", "edit", "cover", "version", "mix", "8d", "bass boosted",
        "unplugged", "demo", "a cappella", "acapella", "karaoke", "orchestral", "piano",
    ]

    /// The version markers in a title ("slowed", "reverb", "remix"…), so "Song" and "Song (Slowed + Reverb)" differ.
    nonisolated static func versionTags(_ title: String) -> Set<String> {
        let lower = title.lowercased()
        return Set(versionWords.filter { word in
            lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
        })
    }

    /// The title without " - Slowed + Reverb" style suffixes (bracketed ones are removed by `normalize`).
    private static func stripVersionWords(_ title: String) -> String {
        guard let dash = title.range(of: " - ", options: .backwards) else { return title }
        let suffix = title[dash.upperBound...]
        return versionTags(String(suffix)).isEmpty ? title : String(title[..<dash.lowerBound])
    }
}
