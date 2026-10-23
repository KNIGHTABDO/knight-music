import Foundation

/// Navidrome smart playlist rules (the `.nsp` criteria format), created through Navidrome's native API.
struct SmartPlaylistRules: Sendable, Equatable {
    var matchAll = true
    var conditions: [SmartPlaylistCondition] = [SmartPlaylistCondition()]
    var sort: SmartPlaylistSort = .random
    var descending = false
    var limit = 100

    /// `{"all": [{"is": {"genre": "Rock"}}], "sort": "random", "order": "asc", "limit": 100}`
    var json: [String: Any] {
        [
            matchAll ? "all" : "any": conditions.compactMap(\.json),
            "sort": sort.rawValue,
            "order": descending ? "desc" : "asc",
            "limit": limit
        ]
    }

    var isValid: Bool { !conditions.isEmpty && conditions.allSatisfy { $0.json != nil } }
}

struct SmartPlaylistCondition: Identifiable, Sendable, Equatable {
    var id = UUID()
    var field: SmartPlaylistField = .genre
    var op: SmartPlaylistOperator = .is
    var text = ""
    var number = 0
    var upperNumber = 0
    var flag = true

    var json: [String: Any]? {
        let value: Any
        switch field.kind {
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            value = trimmed
        case .number, .days:
            if op == .inTheRange {
                value = [min(number, upperNumber), max(number, upperNumber)]
            } else {
                value = number
            }
        case .flag:
            value = flag
        }
        return [op.rawValue: [field.rawValue: value]]
    }
}

enum SmartPlaylistField: String, CaseIterable, Identifiable, Sendable {
    case title, album, artist, albumartist, genre, year, playcount, rating, loved, dateadded, lastplayed, bitrate, filetype

    enum Kind { case text, number, days, flag }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Title"
        case .album: "Album"
        case .artist: "Artist"
        case .albumartist: "Album Artist"
        case .genre: "Genre"
        case .year: "Year"
        case .playcount: "Play Count"
        case .rating: "Rating"
        case .loved: "Loved"
        case .dateadded: "Date Added"
        case .lastplayed: "Last Played"
        case .bitrate: "Bit Rate (kbps)"
        case .filetype: "File Type"
        }
    }

    var kind: Kind {
        switch self {
        case .title, .album, .artist, .albumartist, .genre, .filetype: .text
        case .year, .playcount, .rating, .bitrate: .number
        case .dateadded, .lastplayed: .days
        case .loved: .flag
        }
    }

    var operators: [SmartPlaylistOperator] {
        switch kind {
        case .text: [.is, .isNot, .contains, .notContains, .startsWith, .endsWith]
        case .number: [.is, .isNot, .gt, .lt, .inTheRange]
        case .days: [.inTheLast, .notInTheLast]
        case .flag: [.is]
        }
    }
}

enum SmartPlaylistOperator: String, CaseIterable, Identifiable, Sendable {
    case `is`, isNot, contains, notContains, startsWith, endsWith, gt, lt, inTheRange, inTheLast, notInTheLast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .is: "is"
        case .isNot: "is not"
        case .contains: "contains"
        case .notContains: "does not contain"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .gt: "greater than"
        case .lt: "less than"
        case .inTheRange: "between"
        case .inTheLast: "in the last (days)"
        case .notInTheLast: "not in the last (days)"
        }
    }
}

enum SmartPlaylistSort: String, CaseIterable, Identifiable, Sendable {
    case random, title, artist, album, year, playcount, rating, dateadded, lastplayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .random: "Random"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .playcount: "Play Count"
        case .rating: "Rating"
        case .dateadded: "Date Added"
        case .lastplayed: "Last Played"
        }
    }
}
