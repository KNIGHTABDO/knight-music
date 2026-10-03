import Foundation

/// Persists the list of accounts (JSON in Application Support) and which one is active.
/// Passwords are stored in the Keychain under the account id.
@MainActor @Observable
final class AccountStore {
    private struct FileContents: Codable {
        var accounts: [ServerAccount]
        var activeId: UUID?
    }

    private(set) var accounts: [ServerAccount] = []
    private(set) var activeId: UUID?

    var active: ServerAccount? { accounts.first { $0.id == activeId } }

    init() { load() }

    func password(for id: UUID) -> String? { Keychain.get(account: id.uuidString) }

    func add(_ account: ServerAccount, password: String) throws {
        try Keychain.set(password, account: account.id.uuidString)
        accounts.append(account)
        if activeId == nil { activeId = account.id }
        save()
    }

    func update(_ account: ServerAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    func updatePassword(_ password: String, for id: UUID) throws {
        try Keychain.set(password, account: id.uuidString)
    }

    func setActive(_ id: UUID?) {
        activeId = id
        save()
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        Keychain.delete(account: id.uuidString)
        if activeId == id { activeId = accounts.first?.id }
        save()
    }

    func touchSync(_ id: UUID, at date: Date = Date()) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.lastSyncAt = date
        update(account)
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        LibraryDatabase.applicationSupport.appendingPathComponent("accounts.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(FileContents.self, from: data)
            accounts = file.accounts
            activeId = file.activeId ?? file.accounts.first?.id
        } catch {
            Log.app.error("accounts.json unreadable: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(FileContents(accounts: accounts, activeId: activeId))
            try data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.app.error("accounts.json write failed: \(error)")
        }
    }
}
