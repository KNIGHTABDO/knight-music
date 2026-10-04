import Foundation

/// Fetches AutoMix transition plans from the Navidrome host and keeps them on disk, so pairs heard before
/// mix offline too. Provisional plans (a song not analysed yet) are never cached.
actor AutoMixClient: AutoMixPlanProvider {
    private let directory: URL
    private var memory: [String: AutoMixPlan] = [:]
    private var inflight: [String: Task<AutoMixPlan?, Never>] = [:]
    private let urls: @Sendable (_ path: String, _ items: [URLQueryItem]) -> URL?

    init(urls: @escaping @Sendable (_ path: String, _ items: [URLQueryItem]) -> URL?) {
        self.urls = urls
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("AutoMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
    }

    func plan(from: String, to: String) async -> AutoMixPlan? {
        let key = "\(safeFileComponent(from))__\(safeFileComponent(to))"
        if let hit = memory[key] { return hit }
        if let stored = loadStored(key) {
            memory[key] = stored
            return stored
        }
        if let running = inflight[key] { return await running.value }
        let task = Task { await self.fetch(from: from, to: to) }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result, result.final == true {
            memory[key] = result
            store(result, key: key)
        }
        return result
    }

    private func fetch(from: String, to: String) async -> AutoMixPlan? {
        guard let url = urls("plan", [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]) else {
            return nil
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.playback.warning("AutoMix plan HTTP \(code) for \(from) -> \(to)")
                return nil
            }
            let plan = try JSONDecoder().decode(AutoMixPlan.self, from: data)
            guard plan.version == AutoMixPlan.supportedVersion else {
                Log.playback.warning("AutoMix plan version \(plan.version) not supported")
                return nil
            }
            Log.playback.info("AutoMix \(plan.mode.rawValue) \(from) -> \(to): \(plan.reason ?? "")")
            return plan
        } catch {
            Log.playback.warning("AutoMix plan unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadStored(_ key: String) -> AutoMixPlan? {
        let file = directory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: file),
              let plan = try? JSONDecoder().decode(AutoMixPlan.self, from: data),
              plan.version == AutoMixPlan.supportedVersion else { return nil }
        return plan
    }

    private func store(_ plan: AutoMixPlan, key: String) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
    }
}
