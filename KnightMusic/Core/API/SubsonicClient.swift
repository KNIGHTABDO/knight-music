import Foundation

enum SubsonicError: Error {
    case transport(Error)
    case server(code: Int, message: String)
    case decoding(Error)
}

actor SubsonicClient {
    nonisolated let baseURL: URL

    init(baseURL: URL) { self.baseURL = baseURL }

    nonisolated func streamURL(songId: String, maxBitRate: Int? = nil, format: String? = nil, timeOffset: Int? = nil) -> URL { baseURL }
    nonisolated func downloadURL(songId: String) -> URL { baseURL }
    nonisolated func coverArtURL(id: String, size: Int? = nil) -> URL { baseURL }
}
