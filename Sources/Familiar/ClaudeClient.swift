import Foundation

struct ClaudeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ClaudeReply {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let toolCalls: Int
}

/// A tool's result: plain text, or content blocks (e.g. an image) for the model.
struct ToolResult {
    var content: Any          // String or [[String: Any]] blocks
    var isError = false
    static func text(_ s: String, isError: Bool = false) -> ToolResult { ToolResult(content: s, isError: isError) }
    static func blocks(_ b: [[String: Any]]) -> ToolResult { ToolResult(content: b) }
}

typealias ToolExecutor = (_ name: String, _ input: [String: Any], _ toolset: String?) async -> ToolResult

/// Raw HTTP client for the Claude Messages API with a manual tool-use loop.
final class ClaudeClient {
    var apiKey: String
    var model: String
    var effort: String
    var maxTokens: Int
    var baseURL: URL
    var extraHeaders: [String: String]
    var maxToolRounds = 8
    var betas: [String] = ["server-side-fallback-2026-07-01"]
    /// Checked before every tool round; when true the loop ends gracefully (pending tool calls get an error result).
    var shouldStop: () -> Bool = { false }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 240
        return URLSession(configuration: c)
    }()

    init(config: Config, apiKey: String) {
        self.apiKey = apiKey
        self.model = config.model
        self.effort = config.effort
        self.maxTokens = config.maxTokens
        self.baseURL = URL(string: config.apiBaseURL.isEmpty ? "https://api.anthropic.com" : config.apiBaseURL) ?? URL(string: "https://api.anthropic.com")!
        self.extraHeaders = config.apiHeaders
    }

    /// Runs the conversation until Claude stops calling tools. `messages` is updated in place with every turn.
    func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                  executor: ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
        var totalIn = 0, totalOut = 0, cacheRead = 0, toolCalls = 0
        var rounds = 0
        while true {
            let json = try await post(system: system, tools: tools, messages: messages)
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
            let content = json["content"] as? [[String: Any]] ?? []
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
                        Log.info("tool call: \(toolset.map { "\($0)." } ?? "")\(name) \(Self.describe(input))")
                        let r = await executor(name, input, toolset)
                        toolCalls += 1
                        block["content"] = r.content
                        if r.isError { block["is_error"] = true; if toolset == "computer" { computerFailed = true } }
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
            if stop == "max_tokens" { text += "\n\n_(answer was cut off)_" }
            return ClaudeReply(text: text, inputTokens: totalIn, outputTokens: totalOut, cacheRead: cacheRead, toolCalls: toolCalls)
        }
    }

    /// Short, secret-free description of a tool input for the log.
    static func describe(_ input: [String: Any]) -> String {
        let s = input.map { k, v in "\(k)=\(String(describing: v).prefix(60))" }.sorted().joined(separator: " ")
        return String(s.prefix(200))
    }

    private func post(system: String, tools: [[String: Any]], messages: [[String: Any]]) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "fallbacks": "default",
            "output_config": ["effort": effort],
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
        ]
        if !tools.isEmpty { body["tools"] = tools }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError(message: "No HTTP response.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "unknown"
            throw ClaudeError(message: "API error \(http.statusCode): \(msg)")
        }
        return json
    }
}
