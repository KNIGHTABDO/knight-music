import Foundation

/// Events emitted during streaming responses from Hermes agent.
enum HermesEvent: Sendable, Equatable {
    case textDelta(String)
    case toolStarted(id: String, name: String, argumentsJSON: String)
    case toolFinished(id: String)
    case completed(fullText: String)
    case failed(String)
}

struct RunStartResponse: Codable, Sendable {
    let run_id: String
    let status: String?

    var runId: String { run_id }
}

typealias StartRunResponse = RunStartResponse

struct RunStatusResponse: Codable, Sendable {
    let status: String?
    let completed: Bool?
    let output: String?

    var isCompleted: Bool {
        completed == true || status == "completed"
    }
}

/// Actor responsible for communicating with the Hermes AI agent server.
actor HermesClient {
    private var baseURL: URL?
    private var apiKey: String
    private let session: URLSession
    private var loggedUnknownEvents: Set<String> = []

    init(baseURL: URL? = nil, apiKey: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: config)
    }

    init(settings: HermesSettings) {
        self.baseURL = settings.baseURL
        self.apiKey = settings.apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: config)
    }

    func update(baseURL: URL?, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    struct HealthResponse: Codable, Sendable {
        let status: String
        let platform: String?
        let version: String?
    }

    struct ModelsResponse: Codable, Sendable {
        struct ModelInfo: Codable, Sendable {
            let id: String
        }
        let data: [ModelInfo]?
    }

    func health() async throws -> HealthResponse {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let url = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Health check returned status \(code)"])
        }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    func checkAuth() async throws -> Bool {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 {
                throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Authentication failed. Check your API key."])
            }
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Models check returned status \(code)"])
        }
        return true
    }

    // MARK: - Durable Runs API

    func startRun(conversationId: String, input: String) async throws -> RunStartResponse {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("runs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // ALWAYS prefix the input with [Knight Music]
        let prefixedInput = input.hasPrefix("[Knight Music] ") ? input : "[Knight Music] \(input)"

        let payload: [String: Any] = [
            "model": "hermes-knight",
            "input": prefixedInput,
            "session_id": conversationId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let code = httpResponse.statusCode
            let errStr = String(data: data, encoding: .utf8) ?? "Server returned status \(code)"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Start run failed (\(code)): \(errStr)"])
        }
        return try JSONDecoder().decode(RunStartResponse.self, from: data)
    }

    func runStatus(runId: String) async throws -> RunStatusResponse {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("runs").appendingPathComponent(runId)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let code = httpResponse.statusCode
            let errStr = String(data: data, encoding: .utf8) ?? "Server returned status \(code)"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Run status failed (\(code)): \(errStr)"])
        }
        return try JSONDecoder().decode(RunStatusResponse.self, from: data)
    }

    func stopRun(runId: String) async throws {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("runs").appendingPathComponent(runId).appendingPathComponent("stop")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Stop run failed with status \(code)"])
        }
    }

    func logUnknownEventOnce(_ event: String) {
        guard !loggedUnknownEvents.contains(event) else { return }
        loggedUnknownEvents.insert(event)
        Log.api.warning("Hermes unknown event: \(event)")
    }

    func events(runId: String) -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let baseURL = baseURL else {
                        continuation.finish(throwing: URLError(.badURL))
                        return
                    }
                    let url = baseURL.appendingPathComponent("v1")
                        .appendingPathComponent("runs")
                        .appendingPathComponent(runId)
                        .appendingPathComponent("events")
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let code = httpResponse.statusCode
                        continuation.finish(throwing: URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Server returned status \(code)"]))
                        return
                    }

                    var accumulatedText = ""
                    var hasEmittedCompleted = false
                    var lastToolId: String? = nil

                    eventLoop: for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if chunk == "[DONE]" { break eventLoop }
                        guard !chunk.isEmpty,
                              let data = chunk.data(using: .utf8),
                              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                            continue
                        }

                        let eventType = (json["event"] as? String) ?? (json["type"] as? String) ?? ""

                        // Check failure
                        if eventType == "run.failed" || eventType == "error" || json["error"] != nil {
                            let msg = (json["error"] as? [String: Any])?["message"] as? String
                                ?? json["error"] as? String
                                ?? json["message"] as? String
                                ?? "Run failed"
                            continuation.yield(.failed(msg))
                            continue
                        }

                        switch eventType {
                        case "message.delta":
                            if let delta = (json["delta"] as? String) ?? (json["text"] as? String), !delta.isEmpty {
                                accumulatedText += delta
                                continuation.yield(.textDelta(delta))
                            }

                        case "reasoning.available":
                            // Ignore as specified
                            break

                        case "run.completed":
                            hasEmittedCompleted = true
                            let output = (json["output"] as? String) ?? accumulatedText
                            continuation.yield(.completed(fullText: output))
                            break eventLoop

                        default:
                            let lower = eventType.lowercased()
                            let hasToolInType = lower.contains("tool")
                            let hasToolFields = json["tool_name"] != nil || json["tool"] != nil

                            if hasToolInType || hasToolFields {
                                let status = (json["status"] as? String)?.lowercased() ?? ""
                                let isFinished = lower.contains("finish")
                                    || lower.contains("complete")
                                    || lower.contains("done")
                                    || lower.contains("end")
                                    || status == "completed"
                                    || status == "finished"
                                    || status == "done"

                                if isFinished {
                                    let callId = (json["id"] as? String)
                                        ?? (json["tool_call_id"] as? String)
                                        ?? (json["call_id"] as? String)
                                        ?? lastToolId
                                        ?? ""
                                    continuation.yield(.toolFinished(id: callId))
                                } else {
                                    let callId = (json["id"] as? String)
                                        ?? (json["tool_call_id"] as? String)
                                        ?? (json["call_id"] as? String)
                                        ?? UUID().uuidString
                                    lastToolId = callId
                                    let toolName = (json["tool_name"] as? String)
                                        ?? (json["tool"] as? String)
                                        ?? (json["name"] as? String)
                                        ?? "tool"

                                    var argsDict: [String: Any] = (json["args"] as? [String: Any])
                                        ?? (json["arguments"] as? [String: Any])
                                        ?? [:]
                                    if let preview = json["preview"] as? String {
                                        argsDict["preview"] = preview
                                        if argsDict["command"] == nil {
                                            argsDict["command"] = preview
                                        }
                                    }

                                    let argsStr: String
                                    if !argsDict.isEmpty,
                                       let d = try? JSONSerialization.data(withJSONObject: argsDict),
                                       let s = String(data: d, encoding: .utf8) {
                                        argsStr = s
                                    } else if let strArgs = (json["args"] as? String) ?? (json["arguments"] as? String) {
                                        argsStr = strArgs
                                    } else if let preview = json["preview"] as? String {
                                        argsStr = preview
                                    } else {
                                        argsStr = "{}"
                                    }

                                    continuation.yield(.toolStarted(id: callId, name: toolName, argumentsJSON: argsStr))
                                }
                            } else {
                                if !eventType.isEmpty {
                                    await self.logUnknownEventOnce(eventType)
                                }
                            }
                        }
                    }

                    if !hasEmittedCompleted {
                        continuation.yield(.completed(fullText: accumulatedText))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
