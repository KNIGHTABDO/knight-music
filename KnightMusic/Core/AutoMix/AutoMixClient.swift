import Foundation

/// Fetches AutoMix transition plans from the Navidrome host and keeps them on disk, so pairs heard before
/// mix offline too. Provisional plans (a song not analysed yet) are never cached.
actor AutoMixClient: AutoMixPlanProvider {
    private let directory: URL
    private var memory: [String: AutoMixPlan] = [:]
    private var inflight: [String: Task<AutoMixPlan?, Never>] = [:]
    private var summaries: [String: AutoMixTrackSummary] = [:]
    private let urls: @Sendable (_ path: String, _ items: [URLQueryItem]) -> URL?

    init(urls: @escaping @Sendable (_ path: String, _ items: [URLQueryItem]) -> URL?) {
        self.urls = urls
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("AutoMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
    }

    func plan(from: String, to: String) async -> AutoMixPlan? {
        let key = Self.key(from, to)
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

    func prefetch(pairs: [(from: String, to: String)]) async {
        let missing = pairs.filter { pair in
            let key = Self.key(pair.from, pair.to)
            return memory[key] == nil && loadStored(key) == nil
        }
        guard !missing.isEmpty, let url = urls("plans", []) else { return }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["pairs": missing.prefix(50).map { [$0.from, $0.to] }])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            struct Batch: Decodable { var plans: [AutoMixPlan] }
            let batch = try JSONDecoder().decode(Batch.self, from: data)
            var stored = 0
            for plan in batch.plans where plan.final == true && plan.version == AutoMixPlan.supportedVersion {
                guard let from = plan.from, let to = plan.to else { continue }
                let key = Self.key(from, to)
                memory[key] = plan
                store(plan, key: key)
                stored += 1
            }
            Log.playback.info("AutoMix prefetched \(stored) of \(missing.count) upcoming transitions")
        } catch {
            Log.playback.warning("AutoMix prefetch failed: \(error.localizedDescription)")
        }
    }

    func summary(songId: String) async -> AutoMixTrackSummary? {
        if let hit = summaries[songId] { return hit }
        guard let url = urls("analysis/" + songId, []) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let summary = try JSONDecoder().decode(AutoMixTrackSummary.self, from: data)
            summaries[songId] = summary
            return summary
        } catch {
            Log.playback.warning("AutoMix analysis unavailable for \(songId): \(error.localizedDescription)")
            return nil
        }
    }

    private static func key(_ from: String, _ to: String) -> String {
        "\(safeFileComponent(from))__\(safeFileComponent(to))"
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
        // Plans are refreshed weekly so planner improvements on the server reach stored pairs too.
        if let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 7 * 24 * 3600 {
            return nil
        }
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
