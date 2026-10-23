import Foundation

/// Smart playlists aren't part of the Subsonic API; Navidrome's native REST API (`/auth/login`, `/api/playlist`)
/// stores the same rules a `.nsp` file would.
extension SubsonicClient {
    func createSmartPlaylist(name: String, comment: String, rules: SmartPlaylistRules) async throws -> String {
        let token = try await nativeToken()
        let body: [String: Any] = ["name": name, "comment": comment, "public": false, "rules": rules.json]
        let response: [String: Any] = try await nativeRequest(
            "api/playlist", method: "POST", body: body, headers: ["X-ND-Authorization": "Bearer \(token)"]
        )
        guard let id = response["id"] as? String, !id.isEmpty else {
            throw SubsonicError.server(code: 0, message: "Navidrome didn't return the new playlist.")
        }
        return id
    }

    private func nativeToken() async throws -> String {
        let response: [String: Any] = try await nativeRequest(
            "auth/login", method: "POST", body: ["username": username, "password": password], headers: [:]
        )
        guard let token = response["token"] as? String else {
            throw SubsonicError.server(code: 40, message: "Navidrome login failed.")
        }
        return token
    }

    private func nativeRequest(
        _ path: String, method: String, body: [String: Any], headers: [String: String]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SubsonicError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 { throw SubsonicError.server(code: 40, message: "Unauthorized") }
            throw SubsonicError.http(status: http.statusCode)
        }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw SubsonicError.decoding(error)
        }
    }
}
