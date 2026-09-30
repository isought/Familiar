import Foundation
import FamiliarContracts

/// Raw HTTP client for the Claude Messages API with a manual tool-use loop.
package final class ClaudeClient: ConversationClient {
    package var apiKey: String
    package var model: String
    package var effort: String
    package var maxTokens: Int
    package var baseURL: URL
    package var extraHeaders: [String: String]
    package var maxToolRounds = 8
    /// Server-side refusal fallbacks (the `fallbacks` field and its beta header) exist only on Anthropic's own API.
    /// Gateways and cloud platforms reject them, so they are sent only to api.anthropic.com.
    package var serverFallbacks: Bool
    /// Checked before every tool round; when true the loop ends gracefully (pending tool calls get an error result).
    package var shouldStop: () -> Bool = { false }
    /// Seconds to wait before each retry of a dropped connection or a busy server. Resending is safe: the Messages
    /// call has no side effects, and tools only run here after a reply arrives.
    package var retryDelays: [Double] = [0.5, 2]
    /// A reply cut off inside a tool call can't be used, so it is asked again with double the room, up to this.
    package var maxTokensCeiling = 32_000
    /// Ends a reply that ran out of room, so the person knows it's incomplete.
    package static let cutOffNote = "_(answer was cut off)_"

    private static let retryableErrors: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
    private static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504, 529]

    private let session: URLSession
    private let logger: (String) -> Void

    package init(options: ClaudeAPIOptions, session: URLSession? = nil,
                 logger: @escaping (String) -> Void = { _ in }) {
        self.apiKey = options.apiKey
        self.model = options.model
        self.effort = options.effort
        self.maxTokens = options.maxTokens
        let baseURL = URL(string: options.baseURL.isEmpty ? "https://api.anthropic.com" : options.baseURL) ?? URL(string: "https://api.anthropic.com")!
        self.baseURL = baseURL
        self.serverFallbacks = baseURL.host?.lowercased() == "api.anthropic.com"
        self.extraHeaders = options.headers
        self.logger = logger
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // A non-streamed reply arrives all at once; a long one (a full inbox's findings) can take minutes, and
            // Anthropic's SDKs wait ten.
            configuration.timeoutIntervalForRequest = 600
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Runs the conversation until Claude stops calling tools. `messages` is updated in place with every turn.
    package func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                  executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
        var totalIn = 0, totalOut = 0, cacheRead = 0, toolCalls = 0
        var rounds = 0
        var budget = maxTokens
        while true {
            let json = try await post(system: system, tools: tools, messages: messages, maxTokens: budget)
            let usage = json["usage"] as? [String: Any] ?? [:]
            let read = usage["cache_read_input_tokens"] as? Int ?? 0
            let created = usage["cache_creation_input_tokens"] as? Int ?? 0
            totalIn += (usage["input_tokens"] as? Int ?? 0) + read + created   // total prompt size, all buckets
            totalOut += usage["output_tokens"] as? Int ?? 0
            cacheRead += read

            let stop = json["stop_reason"] as? String ?? ""
            if stop == "refusal" {
                let cat = (json["stop_details"] as? [String: Any])?["category"] as? String ?? "unspecified"
                throw ClaudeError(message: "Claude declined this request (category: \(cat)).")
            }
            var content = json["content"] as? [[String: Any]] ?? []
            if stop == "max_tokens", content.last?["type"] as? String == "tool_use" {
                // Anthropic's advice for a reply cut off inside a tool call: ask again with more room.
                if budget < maxTokensCeiling {
                    let larger = min(budget * 2, maxTokensCeiling)
                    logger("reply cut off inside a tool call at \(budget) tokens; asking again with \(larger)")
                    budget = larger
                    continue
                }
                // Still out of room: an unfinished call can't be answered, so it's left out to keep the history valid.
                content.removeLast()
                if !content.contains(where: { $0["type"] as? String == "text" }) {
                    content.append(["type": "text", "text": "I ran out of room before finishing."])
                }
            }
            // Echo the assistant turn back unchanged (including thinking blocks) so tool loops stay valid.
            messages.append(["role": "assistant", "content": content])

            let uses = content.filter { $0["type"] as? String == "tool_use" }
            if stop == "tool_use", !uses.isEmpty {
                let stopped = shouldStop()
                let overBudget = rounds >= maxToolRounds
                rounds += 1
                var results: [[String: Any]] = []
                var computerFailed = false
                for u in uses {
                    let name = u["name"] as? String ?? "?"
                    let id = u["id"] as? String ?? ""
                    let input = u["input"] as? [String: Any] ?? [:]
                    let toolset = u["toolset_name"] as? String
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": id]
                    if let toolset { block["toolset_name"] = toolset }
                    if stopped || overBudget {
                        block["content"] = stopped ? "Stopped by the user." : "Tool budget exhausted; summarize and stop."
                        block["is_error"] = true
                    } else if toolset == "computer", computerFailed {
                        // Batch rule: run in order, stop at the first failed computer action.
                        block["content"] = "Not executed: an earlier computer action in this turn failed."
                        block["is_error"] = true
                    } else {
                        if toolset == nil { onStatus("Running \(name.replacingOccurrences(of: "__", with: "/"))…") }
                        logger("tool call: \(toolset.map { "\($0)." } ?? "")\(name) \(Self.describe(input))")
                        let r = await executor(name, input, toolset)
                        toolCalls += 1
                        block["content"] = r.content
                        if r.isError {
                            block["is_error"] = true
                            if toolset == "computer" { computerFailed = true }
                            logger("tool error: \(toolset.map { "\($0)." } ?? "")\(name): \(Self.errorLine(r.content))")
                        }
                    }
                    results.append(block)
                }
                messages.append(["role": "user", "content": results])
                if stopped {
                    return ClaudeReply(text: "Stopped.", inputTokens: totalIn, outputTokens: totalOut, cacheRead: cacheRead, toolCalls: toolCalls)
                }
                if overBudget { rounds = maxToolRounds - 1 }   // allow one final summarizing round
                onStatus("Thinking…")
                continue
            }

            var text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if stop == "max_tokens" { text += "\n\n" + Self.cutOffNote }
            return ClaudeReply(text: text, inputTokens: totalIn, outputTokens: totalOut, cacheRead: cacheRead, toolCalls: toolCalls)
        }
    }

    /// A tool's error result as one log line.
    package static func errorLine(_ content: Any) -> String {
        guard let text = content as? String else { return "(non-text result)" }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    /// Short, secret-free description of a tool input for the log.
    package static func describe(_ input: [String: Any]) -> String {
        let s = input.map { k, v in "\(k)=\(String(describing: v).prefix(60))" }.sorted().joined(separator: " ")
        return String(s.prefix(200))
    }

    private func post(system: String, tools: [[String: Any]], messages: [[String: Any]], maxTokens: Int) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort],
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
        ]
        if serverFallbacks { body["fallbacks"] = "default" }
        if !tools.isEmpty { body["tools"] = tools }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A gateway may authenticate through its own header instead (config apiHeaders).
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if serverFallbacks { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let host = baseURL.host ?? baseURL.absoluteString
        var attempt = 0
        while true {
            attempt += 1
            let started = Date()
            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch let error as URLError where error.code != .cancelled {
                let elapsed = Date().timeIntervalSince(started)
                logger("request to \(host) failed: URLError \(error.code.rawValue) after \(Self.seconds(elapsed)) (attempt \(attempt))")
                if Self.retryableErrors.contains(error.code), attempt <= retryDelays.count {
                    try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt - 1] * 1_000_000_000))
                    continue
                }
                throw ClaudeError(message: Self.explain(error, host: host, elapsed: elapsed, attempts: attempt,
                                                        timeout: session.configuration.timeoutIntervalForRequest))
            }
            guard let http = resp as? HTTPURLResponse else { throw ClaudeError(message: "No HTTP response.") }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(http.statusCode) { return json }
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "unknown"
            if Self.retryableStatuses.contains(http.statusCode), attempt <= retryDelays.count {
                let wait = min(Self.retryAfter(http.value(forHTTPHeaderField: "retry-after")) ?? retryDelays[attempt - 1], 30)
                logger("request to \(host): HTTP \(http.statusCode) (attempt \(attempt)); retrying in \(Self.seconds(wait))")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            throw ClaudeError(message: "API error \(http.statusCode): \(msg)" + (attempt > 1 ? " (tried \(attempt) times)" : ""))
        }
    }

    /// What someone can act on when Claude can't be reached: where, what happened, how long, and what to try.
    package static func explain(_ error: URLError, host: String, elapsed: TimeInterval, attempts: Int, timeout: TimeInterval) -> String {
        let tries = attempts > 1 ? " (tried \(attempts) times)" : ""
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return "This Mac is offline, so Noteling can't reach Claude at \(host). Check your connection and try again."
        case .networkConnectionLost:
            return "The connection to \(host) dropped after \(seconds(elapsed))\(tries). This happens on unstable Wi-Fi, right after sleep, or when a VPN or proxy cuts long requests. Check your connection and try again."
        case .timedOut:
            return "\(host) didn't answer within \(seconds(timeout)). Claude may be busy, or a VPN or proxy is holding the request. Try again, or ask something shorter."
        case .cannotFindHost, .dnsLookupFailed:
            return "Noteling couldn't find \(host)\(tries). Check your connection, or the gateway address in Settings if your company uses one."
        case .cannotConnectToHost:
            return "Noteling couldn't connect to \(host)\(tries). Check your connection, or the gateway address in Settings if your company uses one."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return "The secure connection to \(host) failed. A company proxy or network filter may be intercepting it: ask IT, or set your company's gateway in Settings."
        default:
            return "Noteling couldn't reach \(host)\(tries): \(error.localizedDescription) Check your connection and try again."
        }
    }

    /// A Retry-After header in seconds (the HTTP-date form is ignored).
    package static func retryAfter(_ value: String?) -> Double? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), let seconds = Double(text), seconds >= 0 else { return nil }
        return seconds
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value < 10 ? String(format: "%.1f s", value) : "\(Int(value.rounded())) s"
    }
}
