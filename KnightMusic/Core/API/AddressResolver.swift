import Foundation

/// Picks the first reachable address of an account (addresses are ordered by preference), remembers the
/// choice, and is re-run by `AppModel` when the network path changes or the client sees a transport error.
@MainActor @Observable
final class AddressResolver {
    /// Address chosen by the last successful resolution (shown in Settings → Manage Addresses).
    private(set) var currentAddress: URL?
    private(set) var isResolving = false
    private(set) var lastResolvedAt: Date?

    var probeTimeout: TimeInterval = 2.5

    private static func cacheKey(_ id: UUID) -> String { "resolvedAddress.\(id.uuidString)" }

    func cachedAddress(for accountId: UUID) -> URL? {
        UserDefaults.standard.string(forKey: Self.cacheKey(accountId)).flatMap(URL.init(string:))
    }

    func remember(_ address: URL, for accountId: UUID) {
        currentAddress = address
        UserDefaults.standard.set(address.absoluteString, forKey: Self.cacheKey(accountId))
    }

    func forget(accountId: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey(accountId))
    }

    /// Probes all addresses concurrently but honours preference order: the winner is the earliest address
    /// that answers, once every address before it has failed. Returns nil if none answers.
    func resolve(account: ServerAccount, password: String) async -> URL? {
        guard !account.addresses.isEmpty else { return nil }
        isResolving = true
        defer { isResolving = false }
        let timeout = probeTimeout
        let addresses = account.addresses
        let username = account.username

        let winner: URL? = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask {
                    (index, await Self.probe(address, username: username, password: password, timeout: timeout))
                }
            }
            var results: [Int: Bool] = [:]
            for await (index, ok) in group {
                results[index] = ok
                for j in 0..<addresses.count {
                    guard let r = results[j] else { break }
                    if r {
                        group.cancelAll()
                        return addresses[j]
                    }
                }
            }
            return nil
        }
        lastResolvedAt = Date()
        if let winner {
            remember(winner, for: account.id)
            Log.network.info("resolved \(account.name) -> \(winner.absoluteString)")
        } else {
            Log.network.warning("no reachable address for \(account.name)")
        }
        return winner
    }

    nonisolated static func probe(_ address: URL, username: String, password: String, timeout: TimeInterval) async -> Bool {
        let client = SubsonicClient(baseURL: address, username: username, password: password, requestTimeout: timeout, maxAttempts: 1)
        do {
            try await client.ping()
            return true
        } catch let error as SubsonicError {
            // The server answered (even with an auth error): the address is reachable.
            if case .server = error { return true }
            return false
        } catch {
            return false
        }
    }

    /// Turns user input ("192.168.1.5:4533", "https://music.example.com/") into a base URL, or nil.
    static func normalize(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "http://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        if t.lowercased().hasSuffix("/rest") { t.removeLast(5) }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
