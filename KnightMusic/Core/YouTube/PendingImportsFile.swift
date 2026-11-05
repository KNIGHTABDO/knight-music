import Foundation

/// An "Add to Navidrome" request that hasn't been confirmed in the library yet.
struct PendingImport: Codable {
    let song: Song
    let force: Bool
    let accountId: UUID
    let existingSongIds: Set<String>
    let conversationId: String?
}

/// Survives iOS closing the app while a song is still being added.
enum PendingImportsFile {
    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("pending-imports.json")
    }

    static func load() -> [PendingImport] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([PendingImport].self, from: data)
        } catch {
            Log.api.warning("Couldn't read pending imports: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ imports: [PendingImport]) {
        guard let url else { return }
        do {
            if imports.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(imports).write(to: url, options: .atomic)
        } catch {
            Log.api.warning("Couldn't save pending imports: \(error.localizedDescription)")
        }
    }
}
