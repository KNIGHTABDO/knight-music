import Foundation

/// Events emitted during streaming responses from Hermes agent.
enum HermesEvent: Sendable, Equatable {
    case textDelta(String)
    case toolStarted(id: String, name: String, argumentsJSON: String)
    case toolFinished(id: String)
    case completed(fullText: String)
    case failed(String)
}

/// Actor responsible for communicating with the Hermes AI agent server.
actor HermesClient {
    private var baseURL: URL?
    private var apiKey: String
    private let session: URLSession

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


        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 {
                throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Authentication failed. Check your API key."])
            }
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Models check returned status \(code)"])
        }
        return true
    }

    func stream(conversation: String, input: String) -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let baseURL = baseURL else {
                        continuation.finish(throwing: URLError(.badURL))
                        return
                    }
                    let url = baseURL.appendingPathComponent("v1").appendingPathComponent("responses")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")


                    // ALWAYS prefix the input with [Knight Music]
                    let prefixedInput = input.hasPrefix("[Knight Music] ") ? input : "[Knight Music] \(input)"

                    let payload: [String: Any] = [
                        "model": "hermes-knight",
                        "stream": true,
                        "store": true,
                        "conversation": conversation,
                        "input": prefixedInput
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

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

                    var currentEvent = ""
                    var currentData = ""
                    var accumulatedText = ""
                    var hasEmittedCompleted = false

                    func dispatchEvent(event: String, dataStr: String) {
                        guard !dataStr.isEmpty else { return }
                        guard let data = dataStr.data(using: .utf8),
                              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                            return
                        }

                        if event == "error" || event == "response.failed" || (json["type"] as? String) == "response.failed" {
                            let msg = (json["error"] as? [String: Any])?["message"] as? String
                                ?? json["error"] as? String
                                ?? json["message"] as? String
                                ?? "Streaming failed"
                            continuation.yield(.failed(msg))
                            return
                        }

                        let type = event.isEmpty ? (json["type"] as? String ?? "") : event
                        switch type {
                        case "response.output_item.added":
                            if let item = json["item"] as? [String: Any] {
                                let type = item["type"] as? String
                                if type == "function_call" {
                                    let name = (item["name"] as? String) ?? "tool"
                                    let callId = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                                    let args: String
                                    if let strArgs = item["arguments"] as? String {
                                        args = strArgs
                                    } else if let dictArgs = item["arguments"] as? [String: Any],
                                              let d = try? JSONSerialization.data(withJSONObject: dictArgs),
                                              let s = String(data: d, encoding: .utf8) {
                                        args = s
                                    } else {
                                        args = "{}"
                                    }
                                    continuation.yield(.toolStarted(id: callId, name: name, argumentsJSON: args))
                                }
                            }

                        case "response.output_item.done":
                            if let item = json["item"] as? [String: Any] {
                                let type = item["type"] as? String
                                if type == "function_call" || type == "function_call_output" {
                                    let callId = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
                                    if !callId.isEmpty {
                                        continuation.yield(.toolFinished(id: callId))
                                    }
                                }
                            }

                        case "response.output_text.delta":
                            if let delta = json["delta"] as? String, !delta.isEmpty {
                                accumulatedText += delta
                                continuation.yield(.textDelta(delta))
                            }

                        case "response.completed":
                            hasEmittedCompleted = true
                            continuation.yield(.completed(fullText: accumulatedText))

                        default:
                            break
                        }
                    }

                    // `AsyncLineSequence` drops empty lines, so the blank line that terminates an SSE event never
                    // arrives. Hermes sends each event's JSON on a single `data:` line, so dispatch on every
                    // `data:` line (and flush anything pending when a new `event:` starts).
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.hasPrefix("event:") {
                            if !currentData.isEmpty {
                                dispatchEvent(event: currentEvent, dataStr: currentData)
                                currentData = ""
                            }
                            currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if chunk == "[DONE]" { break }
                            dispatchEvent(event: currentEvent, dataStr: chunk)
                            currentEvent = ""
                            currentData = ""
                        }
                    }

                    // Any trailing event
                    if !currentEvent.isEmpty || !currentData.isEmpty {
                        dispatchEvent(event: currentEvent, dataStr: currentData)
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
