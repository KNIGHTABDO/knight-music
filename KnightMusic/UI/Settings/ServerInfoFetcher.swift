import Foundation
import SwiftUI

struct SubsonicPingResult: Sendable {
    var status: String
    var type: String?
    var version: String?
    var serverVersion: String?
    var openSubsonic: Bool?
}

private struct PingResponseEnvelope: Decodable {
    struct Response: Decodable {
        let status: String
        let version: String?
        let type: String?
        let serverVersion: String?
        let openSubsonic: Bool?
    }
    let response: Response

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

/// Helper service that fetches server type and version metadata from a Subsonic ping call.
@MainActor @Observable
final class ServerInfoFetcher {
    static let shared = ServerInfoFetcher()

    var pingResult: SubsonicPingResult?
    var isFetching = false
    var lastError: String?

    func fetch(baseURL: URL, username: String, password: String) async -> SubsonicPingResult? {
        isFetching = true
        defer { isFetching = false }

        var endpoint = baseURL
        if !endpoint.path.hasSuffix("/rest") {
            endpoint = endpoint.appendingPathComponent("rest")
        }
        endpoint = endpoint.appendingPathComponent("ping")

        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            lastError = "Invalid URL"
            return nil
        }

        let salt = SubsonicClient.randomSalt()
        let token = SubsonicClient.md5(password + salt)
        comps.queryItems = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: SubsonicClient.apiVersion),
            URLQueryItem(name: "c", value: SubsonicClient.clientName),
            URLQueryItem(name: "f", value: "json")
        ]

        guard let requestURL = comps.url else {
            lastError = "Invalid URL"
            return nil
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "HTTP \(http.statusCode)"
                return nil
            }
            let envelope = try JSONDecoder().decode(PingResponseEnvelope.self, from: data)
            let result = SubsonicPingResult(
                status: envelope.response.status,
                type: envelope.response.type,
                version: envelope.response.version,
                serverVersion: envelope.response.serverVersion,
                openSubsonic: envelope.response.openSubsonic
            )
            self.pingResult = result
            self.lastError = nil
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func fetchIfNeeded(app: AppModel) async {
        guard let account = app.activeAccount,
              let password = app.accounts.password(for: account.id) else {
            return
        }
        let url = app.client?.baseURL ?? app.addressResolver.currentAddress ?? account.addresses.first
        guard let url else { return }
        _ = await fetch(baseURL: url, username: account.username, password: password)
    }
}
