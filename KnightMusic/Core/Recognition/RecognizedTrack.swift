import Foundation

struct RecognizedTrack: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let appleMusicURL: URL?
    let isrc: String?
    let recognizedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        album: String? = nil,
        artworkURL: URL? = nil,
        appleMusicURL: URL? = nil,
        isrc: String? = nil,
        recognizedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.appleMusicURL = appleMusicURL
        self.isrc = isrc
        self.recognizedAt = recognizedAt
    }
}

@MainActor
@Observable
final class RecognizedTracksStore {
    static let shared = RecognizedTracksStore()

    private(set) var tracks: [RecognizedTrack] = []

    private let storageKey = "knightmusic.recognized_tracks"

    private init() {
        load()
    }

    func add(_ track: RecognizedTrack) {
        // Deduplicate existing identical song
        tracks.removeAll {
            $0.id == track.id ||
            ($0.title.caseInsensitiveCompare(track.title) == .orderedSame &&
             $0.artist.caseInsensitiveCompare(track.artist) == .orderedSame)
        }
        tracks.insert(track, at: 0)
        if tracks.count > 100 {
            tracks = Array(tracks.prefix(100))
        }
        save()
    }

    func remove(id: String) {
        tracks.removeAll { $0.id == id }
        save()
    }

    func clear() {
        tracks.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecognizedTrack].self, from: data) else {
            return
        }
        tracks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
