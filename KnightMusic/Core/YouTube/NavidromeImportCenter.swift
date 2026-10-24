import Foundation
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
        var conversationId: String?
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
            confirmation = Confirmation(song: song, matches: matches, kind: sameVersion ? .same : .similar)
            return
        }
        enqueue(song, force: false)
    }

    func resolve(_ confirmation: Confirmation, addAnyway: Bool) {
        self.confirmation = nil
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
        withAnimation(.smooth) { jobs.append(Job(song: song, force: force)) }
        ui?.showToast("Sending \u{201C}\(song.title)\u{201D} to Knight…")
        guard runner == nil else { return }
        runner = Task { [weak self] in
            await self?.drain()
            self?.runner = nil
        }
    }

    private func drain() async {
        while true {
            while let index = jobs.firstIndex(where: { $0.state == .waiting }) {
                await run(jobs[index].id)
            }
            try? await Task.sleep(for: .seconds(6))
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
        guard let app, let ui, let song = job(id)?.song else { return }
        let hermes = app.hermes

        guard hermes.settings.isConfigured else {
            update(id) { $0.state = .working; $0.stage = "Downloading on the server…" }
            switch await YouTubeImporter.add(song) {
            case .added: finish(id, .done)
            case .failed(let message): finish(id, .failed(message))
            }
            return
        }

        // Knight runs one conversation at a time; never cut off one the user started.
        update(id) { $0.stage = "Waiting for Knight…" }
        while hermes.isRunning {
            try? await Task.sleep(for: .seconds(1))
        }

        let conversationId = "km-\(UUID().uuidString.lowercased())"
        update(id) { $0.conversationId = conversationId; $0.state = .working; $0.stage = "Knight is on it…" }
        hermes.sendMessage(conversationId: conversationId, text: prompt(for: song, force: job(id)?.force ?? false),
                           app: app, library: app.library, artwork: app.artwork, ui: ui)

        var sawRun = false
        let started = Date()
        while true {
            try? await Task.sleep(for: .seconds(1))
            let active = hermes.isRunning && hermes.activeConversationId == conversationId
            if active {
                sawRun = true
                if let step = hermes.activeToolSteps.last {
                    update(id) { $0.stage = step.label }
                }
                continue
            }
            if !sawRun && Date().timeIntervalSince(started) < 5 { continue }

            guard let reply = hermes.store.conversation(for: conversationId)?.messages.last(where: { $0.role == .assistant })
            else { return finish(id, .failed("Knight didn't answer")) }

            if reply.status == "failed" || reply.status == "stopped" {
                return finish(id, .failed("Knight couldn't finish the import"))
            }
            if reply.addedTracks.isEmpty && reply.matchedSongIds.isEmpty {
                return finish(id, .failed("Knight couldn't add \u{201C}\(song.title)\u{201D}. Open Knight for details."))
            }
            if !reply.matchedSongIds.isEmpty || !(hermes.matchedSongs[reply.id] ?? []).isEmpty {
                return finish(id, .done)
            }
            switch hermes.importStatus[reply.id] {
            case "Not found yet":
                return finish(id, .failed("Knight added it, but Navidrome hasn't picked it up yet"))
            case nil where Date().timeIntervalSince(started) > 20:
                return finish(id, .done)
            default:
                update(id) { $0.state = .importing; $0.stage = "Waiting for Navidrome to scan…" }
            }
        }
    }

    private func finish(_ id: UUID, _ state: Job.State) {
        guard let title = job(id)?.song.title else { return }
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

    private static let versionWords = [
        "slowed", "reverb", "sped up", "speed up", "nightcore", "remix", "live", "acoustic", "instrumental",
        "remaster", "remastered", "extended", "radio edit", "edit", "cover", "version", "mix", "8d", "bass boosted",
        "unplugged", "demo", "a cappella", "acapella", "karaoke", "orchestral", "piano",
    ]

    /// The version markers in a title ("slowed", "reverb", "remix"…), so "Song" and "Song (Slowed + Reverb)" differ.
    static func versionTags(_ title: String) -> Set<String> {
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
