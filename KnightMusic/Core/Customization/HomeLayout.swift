import Foundation

/// Home shelves the user can reorder and hide (Settings → Customize → Home).
enum HomeSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case topPicks, upNext, continueListening, recentlyPlayed, listenAgain, recentlyAdded, onThisDay
    case rediscover, mostPlayed, newArtists, genres, favoriteAlbums, random, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topPicks: "Top Picks"
        case .upNext: "Up Next"
        case .continueListening: "Continue Listening"
        case .recentlyPlayed: "Recently Played"
        case .listenAgain: "Listen Again"
        case .recentlyAdded: "Recently Added"
        case .onThisDay: "On This Day"
        case .rediscover: "Rediscover"
        case .mostPlayed: "Most Played"
        case .newArtists: "New Artists"
        case .genres: "Genre Shelves"
        case .favoriteAlbums: "Favorite Albums"
        case .random: "Random"
        case .playlists: "Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .topPicks: "star.square.on.square"
        case .upNext: "text.line.first.and.arrowtriangle.forward"
        case .continueListening: "play.circle"
        case .recentlyPlayed: "clock"
        case .listenAgain: "arrow.counterclockwise"
        case .recentlyAdded: "plus.square.on.square"
        case .onThisDay: "calendar"
        case .rediscover: "sparkle.magnifyingglass"
        case .mostPlayed: "flame"
        case .newArtists: "music.mic"
        case .genres: "guitars"
        case .favoriteAlbums: "heart"
        case .random: "shuffle"
        case .playlists: "music.note.list"
        }
    }

    /// Keeps the user's order, drops unknown ids and appends sections added in later versions.
    static func normalized(_ order: [HomeSection]) -> [HomeSection] {
        var seen = Set<HomeSection>()
        let kept = order.filter { seen.insert($0).inserted }
        return kept + allCases.filter { !seen.contains($0) }
    }
}

/// Which tab the app opens on.
enum StartTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case home, library, search, knight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .search: "Search"
        case .knight: "Knight"
        }
    }
}

enum HapticsLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, subtle, normal, strong
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What shaking the phone does.
enum ShakeAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, nextSong, shuffleLibrary, surpriseLook
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Nothing"
        case .nextSong: "Next Song"
        case .shuffleLibrary: "Shuffle Everything"
        case .surpriseLook: "Surprise Look"
        }
    }
}
