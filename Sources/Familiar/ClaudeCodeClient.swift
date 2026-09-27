import Foundation

/// Runs the user's unmodified, signed-in Claude Code executable. Familiar owns
/// conversation history and all tools; the CLI owns authentication and its loop.
final class ClaudeCodeClient: ConversationClient {
    var effort: String
    var maxTokens: Int
    var maxToolRounds = 8
    var shouldStop: () -> Bool = { false }
    var requestTimeout: TimeInterval = 300
    private let config: Config

    init(config: Config) {
        self.config = config
        effort = config.effort
        maxTokens = config.maxTokens
    }

    static func executable(config: Config) -> String? {
        let fm = FileManager.default
        let specified = config.claudePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = fm.homeDirectoryForCurrentUser.path
        let directories = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        if !specified.isEmpty {
            let expanded = (specified as NSString).expandingTildeInPath
            if expanded.contains("/") { return fm.isExecutableFile(atPath: expanded) ? expanded : nil }
            return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(expanded).path }
                .first { fm.isExecutableFile(atPath: $0) }
        }
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("claude").path }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    /// Never inspect or export credentials: ask the installed CLI about its login.
    static func authenticationStatus(config: Config) async -> String {
        guard let executable = executable(config: config) else { return "Claude Code not found. Install it, or set its executable path." }
        do {
            let workspace = try CLIWorkspace()
            defer { workspace.close() }
            let process = try workspace.process(executable: executable,
                                                arguments: ["auth", "status", "--json"], environment: environment())
            defer { stop(process) }
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning {
                if Task.isCancelled || Date() > deadline {
                    stop(process)
                    return "Claude Code login check timed out. Try claude auth status in Terminal."
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let output = try Data(contentsOf: workspace.output)
            guard let status = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                return "Could not check login. Update Claude Code and run claude auth login in Terminal."
            }
            guard status["loggedIn"] as? Bool == true else { return "Not signed in. Run claude auth login in Terminal." }
            let method = status["authMethod"] as? String ?? ""
            if method == "claude.ai" {
                let plan = status["subscriptionType"] as? String ?? ""
                let label = ["free", "pro", "max", "team", "enterprise"].contains(plan.lowercased()) ? " (\(plan.capitalized))" : ""
                return "Signed in to Claude\(label). Uses your plan's allowance."
            }
            return "Claude Code is signed in using \(method == "api_key" ? "an API key" : "its configured account"). For a Claude plan, run claude auth login."
        } catch {
            return "Could not check Claude Code login. Run claude auth status in Terminal."
        }
    }

    func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                  executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
        guard let executable = Self.executable(config: config) else {
            throw ClaudeError(message: "Claude Code was not found. Install it, sign in with claude auth login, then set its path in Familiar Settings if needed.")
        }
        let workspace = try CLIWorkspace()
        defer { workspace.close() }
        let bindings = Self.toolBindings(tools)
        let byName = Dictionary(uniqueKeysWithValues: bindings.map { ($0.name, $0) })
        try workspace.writeJSON(bindings.map(\.definition), to: "tools.json")
        let mcp: [String: Any]
        if bindings.isEmpty {
            mcp = ["mcpServers": [String: Any]()]
        } else {
            let runner = ScriptRunner(config: config)
            let helper = runner.helpers.appendingPathComponent("claude_mcp.py").path
            guard FileManager.default.fileExists(atPath: helper) else {
                throw ClaudeError(message: "Familiar's Claude Code tool bridge is missing. Rebuild or reinstall Familiar.")
            }
            let command: String
            let args: [String]
            if let uv = runner.uv {
                command = uv
                args = ["run", "--no-project", "--quiet", helper, workspace.root.path]
            } else if let python = runner.python {
                command = python
                args = [helper, workspace.root.path]
            } else {
                throw ClaudeError(message: "Claude Code tools need Familiar's bundled uv or Python 3. Reinstall Familiar or install uv.")
            }
            mcp = ["mcpServers": ["familiar": ["type": "stdio", "command": command, "args": args]]]
        }
        try workspace.writeJSON(mcp, to: "mcp.json")
        var input = try JSONSerialization.data(withJSONObject: Self.inputMessage(messages: messages))
        input.append(0x0a)
        try workspace.write(input, to: "input.jsonl")

        var args = ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--no-session-persistence", "--tools", "", "--disable-slash-commands", "--no-chrome",
                    "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                    "--strict-mcp-config", "--mcp-config", workspace.root.appendingPathComponent("mcp.json").path,
                    "--permission-mode", "dontAsk", "--max-turns", String(max(1, maxToolRounds + 1)),
                    "--system-prompt", system + "\n\nYou are running inside Familiar. Use only the supplied Familiar tools. Tool names are prefixed with mcp__familiar__; computer actions are named computer__screenshot, computer__left_click, etc. Earlier conversation is historical context. Answer the latest user request."]
        if !bindings.isEmpty { args += ["--allowedTools", "mcp__familiar__*"] }
        let model = config.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { args += ["--model", model] }
        args += ["--effort", effort == "low" ? "low" : effort == "medium" ? "medium" : "high"]
        var environment = Self.environment()
        environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(max(256, maxTokens))
        let process = try workspace.process(executable: executable, arguments: args, environment: environment,
                                            input: workspace.root.appendingPathComponent("input.jsonl"))
        var pending: PendingCLITool?
        defer {
            pending?.task.cancel()
            Self.stop(process)
        }
        do {
            do { try process.run() } catch {
                throw ClaudeError(message: "Could not start Claude Code. Check its executable path in Familiar Settings.")
            }
            onStatus("Thinking with Claude Code…")
            let deadline = Date().addingTimeInterval(requestTimeout)
            var toolCalls = 0
            var computerFailed = false
            while process.isRunning {
                if Task.isCancelled { throw CancellationError() }
                if shouldStop() {
                    if let pending { Self.appendResult(.text("Stopped by the user.", isError: true), pending: pending, messages: &messages) }
                    pending?.task.cancel()
                    Self.stop(process)
                    if let pending { await pending.task.value }
                    messages.append(["role": "assistant", "content": [["type": "text", "text": "Stopped."]]])
                    return ClaudeReply(text: "Stopped.", inputTokens: 0, outputTokens: 0, cacheRead: 0, toolCalls: toolCalls)
                }
                if Date() > deadline {
                    throw ClaudeError(message: "Claude Code timed out. Try again with a smaller request.")
                }
                let outputSize = (try? FileManager.default.attributesOfItem(atPath: workspace.output.path)[.size] as? NSNumber)?.intValue ?? 0
                if outputSize > 64 * 1024 * 1024 { throw ClaudeError(message: "Claude Code returned too much output. Start a new conversation and try a smaller request.") }

                if let active = pending, let result = active.result.take() {
                    Self.appendResult(result, pending: active, messages: &messages)
                    if result.isError && active.binding.toolset == "computer" { computerFailed = true }
                    try workspace.writeJSON(Self.mcpResult(result), to: "responses/\(active.identifier).json")
                    pending = nil
                    onStatus("Thinking with Claude Code…")
                }
                if pending == nil,
                   let request = try FileManager.default.contentsOfDirectory(at: workspace.requests, includingPropertiesForKeys: nil)
                    .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                    let data = try Data(contentsOf: request)
                    try FileManager.default.removeItem(at: request)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let name = json["name"] as? String, let binding = byName[name],
                          let arguments = json["arguments"] as? [String: Any] else {
                        try workspace.writeJSON(Self.mcpResult(.text("Unknown tool or invalid arguments.", isError: true)),
                                                to: "responses/\(request.lastPathComponent)")
                        continue
                    }
                    let identifier = request.deletingPathExtension().lastPathComponent
                    var use: [String: Any] = ["type": "tool_use", "id": identifier, "name": binding.originalName, "input": arguments]
                    if let toolset = binding.toolset { use["toolset_name"] = toolset }
                    messages.append(["role": "assistant", "content": [use]])
                    let resultBox = CLIToolResultBox()
                    let failed = computerFailed && binding.toolset == "computer"
                    let invalid = !Self.validComputerArguments(arguments, for: binding)
                    if !failed && !invalid { toolCalls += 1 }
                    onStatus("Running \(binding.originalName.replacingOccurrences(of: "__", with: "/"))…")
                    let task = Task {
                        if Task.isCancelled || self.shouldStop() { resultBox.put(.text("Stopped by the user.", isError: true)); return }
                        if failed { resultBox.put(.text("Not executed: an earlier computer action failed. Stop and explain the failure.", isError: true)); return }
                        if invalid { resultBox.put(.text("Invalid computer action arguments. Stop and explain the failure.", isError: true)); return }
                        resultBox.put(await executor(binding.originalName, arguments, binding.toolset))
                    }
                    pending = PendingCLITool(identifier: identifier, binding: binding, result: resultBox, task: task)
                }
                do { try await Task.sleep(nanoseconds: 40_000_000) } catch { /* Observe cancellation above. */ }
            }
            if let pending {
                pending.task.cancel()
                await pending.task.value
                if let result = pending.result.take() { Self.appendResult(result, pending: pending, messages: &messages) }
            }
            try Task.checkCancellation()

            let stdout = try Data(contentsOf: workspace.output)
            let events = String(decoding: stdout, as: UTF8.self).split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard let result = events.last(where: { $0["type"] as? String == "result" }) else {
                let stderr = (try? String(contentsOf: workspace.errorOutput, encoding: .utf8)) ?? ""
                throw ClaudeError(message: Self.failureMessage(String(decoding: stdout, as: UTF8.self) + stderr))
            }
            guard process.terminationStatus == 0, result["is_error"] as? Bool != true,
                  result["subtype"] as? String == "success" else {
                if result["subtype"] as? String == "error_max_turns" {
                    throw ClaudeError(message: "Claude Code reached Familiar's tool limit. Ask a follow-up to continue.")
                }
                throw ClaudeError(message: Self.failureMessage(String(decoding: stdout, as: UTF8.self)))
            }
            let answer = result["result"] as? String ?? ""
            guard !answer.isEmpty else { throw ClaudeError(message: "Claude Code returned an empty answer. Try again.") }
            let usage = result["usage"] as? [String: Any] ?? [:]
            let read = usage["cache_read_input_tokens"] as? Int ?? 0
            let created = usage["cache_creation_input_tokens"] as? Int ?? 0
            messages.append(["role": "assistant", "content": [["type": "text", "text": answer]]])
            return ClaudeReply(text: answer,
                               inputTokens: (usage["input_tokens"] as? Int ?? 0) + read + created,
                               outputTokens: usage["output_tokens"] as? Int ?? 0, cacheRead: read, toolCalls: toolCalls)
        } catch {
            Self.stop(process)
            pending?.task.cancel()
            // Existing native/script executors have their own bounded work.
            // Drain it before ending the turn so a stopped turn cannot act later.
            if let pending { await pending.task.value }
            throw error
        }
    }

    /// Preserve the CLI's normal login while excluding API/gateway/provider and
    /// nested-session overrides inherited from an app launcher or development shell.
    static func environment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = source.filter {
            !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [env["PATH"] ?? "", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return env
    }

    static func inputMessage(messages: [[String: Any]]) -> [String: Any] {
        var content: [[String: Any]] = []
        if messages.count > 1 {
            let history = messages.dropLast().map { message in
                "\(message["role"] as? String ?? "user"):\n\(historyText(message["content"]))"
            }.joined(separator: "\n\n")
            content.append(["type": "text", "text": "Earlier conversation (historical context):\n\(history)\n\nLatest user request follows:"])
        }
        if let latest = messages.last {
            if let text = latest["content"] as? String { content.append(["type": "text", "text": text]) }
            else if let blocks = latest["content"] as? [[String: Any]] {
                for block in blocks {
                    if block["type"] as? String == "text", let text = block["text"] as? String {
                        content.append(["type": "text", "text": text])
                    } else if block["type"] as? String == "image", let source = block["source"] as? [String: Any] {
                        content.append(["type": "image", "source": source])
                    } else {
                        let text = historyText([block])
                        if !text.isEmpty { content.append(["type": "text", "text": text]) }
                    }
                }
            }
        }
        if content.isEmpty { content = [["type": "text", "text": "Hello."]] }
        return ["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull(), "session_id": ""]
    }

    private static func historyText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "tool_use":
                let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:], options: [.sortedKeys])) ?? Data()
                return "Tool \(block["name"] as? String ?? "tool"): \(String(decoding: input, as: UTF8.self))"
            case "tool_result": return "Tool result: \(historyText(block["content"]))"
            case "image": return "[Earlier screenshot omitted; take a fresh screenshot if needed.]"
            default: return nil // Thinking/signature blocks belong to the previous API session.
            }
        }.joined(separator: "\n")
    }

    static func mcpResult(_ result: ToolResult) -> [String: Any] {
        let content: [[String: Any]]
        if let text = result.content as? String { content = [["type": "text", "text": text]] }
        else if let blocks = result.content as? [[String: Any]] {
            content = blocks.compactMap { block in
                if block["type"] as? String == "text", let text = block["text"] as? String { return ["type": "text", "text": text] }
                if block["type"] as? String == "image", let source = block["source"] as? [String: Any],
                   source["type"] as? String == "base64", let data = source["data"] as? String,
                   let mime = source["media_type"] as? String { return ["type": "image", "data": data, "mimeType": mime] }
                return nil
            }
        } else { content = [["type": "text", "text": "Tool returned no supported content."]] }
        return ["content": content, "isError": result.isError]
    }

    private static func appendResult(_ result: ToolResult, pending: PendingCLITool, messages: inout [[String: Any]]) {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": pending.identifier, "content": result.content, "is_error": result.isError]
        if let toolset = pending.binding.toolset { block["toolset_name"] = toolset }
        messages.append(["role": "user", "content": [block]])
    }

    private static func failureMessage(_ output: String) -> String {
        let text = output.lowercased()
        if ["not logged in", "authentication", "oauth", "invalid api key", "please run /login"].contains(where: text.contains) {
            return "Claude Code needs a valid login. Run claude auth login in Terminal, then try again."
        }
        if ["rate_limit", "rate limit", "usage limit", "hit your limit"].contains(where: text.contains) {
            return "Your Claude Code usage limit was reached. Wait for your plan's allowance to reset, or switch to API mode."
        }
        if ["unknown option", "unknown command", "unrecognized option"].contains(where: text.contains) {
            return "This Claude Code version is too old. Run claude update in Terminal and try again."
        }
        return "Claude Code could not complete the request. Check your connection and run claude auth status in Terminal, then try again."
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    static func toolBindings(_ definitions: [[String: Any]]) -> [CLIToolBinding] {
        var result: [CLIToolBinding] = []
        var used = Set<String>()
        let hasComputer = definitions.contains { ($0["type"] as? String)?.hasPrefix("computer_toolset_") == true }
        let reserved = hasComputer ? Set(computerBindings.map(\.name)) : []
        for definition in definitions {
            if (definition["type"] as? String)?.hasPrefix("computer_toolset_") == true {
                for binding in computerBindings where used.insert(binding.name).inserted { result.append(binding) }
                continue
            }
            guard let original = definition["name"] as? String else { continue }
            var name = original
            if name.isEmpty || name.count > 64 || name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil || used.contains(name) || reserved.contains(name) {
                name = "familiar_tool_\(result.count)"
                while used.contains(name) { name += "_" }
            }
            used.insert(name)
            result.append(CLIToolBinding(name: name, originalName: original, toolset: nil,
                                         definition: ["name": name, "description": definition["description"] as? String ?? original,
                                                      "inputSchema": definition["input_schema"] ?? ["type": "object", "properties": [:]]]))
        }
        return result
    }

    /// MCP transports schemas but does not enforce them. Validate the native
    /// computer subset here before numeric conversions or any input events.
    static func validComputerArguments(_ arguments: [String: Any], for binding: CLIToolBinding) -> Bool {
        guard binding.toolset == "computer" else { return true }
        guard let schema = binding.definition["inputSchema"] as? [String: Any] else { return false }
        return matches(arguments, schema: schema)
    }

    private static func matches(_ value: Any, schema: [String: Any]) -> Bool {
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any], let properties = schema["properties"] as? [String: Any] else { return false }
            let required = schema["required"] as? [String] ?? []
            guard required.allSatisfy({ object[$0] != nil }) else { return false }
            for (name, value) in object {
                guard let property = properties[name] as? [String: Any], matches(value, schema: property) else { return false }
            }
            return true
        case "array":
            guard let array = value as? [Any], let items = schema["items"] as? [String: Any],
                  array.count >= (schema["minItems"] as? Int ?? 0), array.count <= (schema["maxItems"] as? Int ?? Int.max) else { return false }
            return array.allSatisfy { matches($0, schema: items) }
        case "string":
            guard let text = value as? String else { return false }
            return (schema["enum"] as? [String]).map { $0.contains(text) } ?? true
        case "integer", "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let double = number.doubleValue
            guard double.isFinite else { return false }
            if schema["type"] as? String == "integer", double.rounded() != double { return false }
            if let minimum = schema["minimum"] as? NSNumber, double < minimum.doubleValue { return false }
            if let maximum = schema["maximum"] as? NSNumber, double > maximum.doubleValue { return false }
            return true
        default: return false
        }
    }

    private static var computerBindings: [CLIToolBinding] {
        let coordinate: [String: Any] = ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 100_000], "minItems": 2, "maxItems": 2,
                                         "description": "[x,y] in screenshot pixels"]
        let text: [String: Any] = ["type": "string"]
        let duration: [String: Any] = ["type": "number", "minimum": 0, "maximum": 30]
        var definitions: [(String, String, [String: Any], [String])] = [
            ("screenshot", "Capture the display before choosing coordinates.", [:], []),
            ("zoom", "Zoom into a screenshot region [left,top,right,bottom] in screenshot pixels.",
             ["region": ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 100_000], "minItems": 4, "maxItems": 4]], ["region"]),
            ("mouse_move", "Move the mouse to screenshot coordinates.", ["coordinate": coordinate], ["coordinate"]),
            ("left_click_drag", "Drag from start_coordinate to coordinate.", ["start_coordinate": coordinate, "coordinate": coordinate, "text": text], ["start_coordinate", "coordinate"]),
            ("left_mouse_down", "Press the left mouse button at the current cursor.", [:], []),
            ("left_mouse_up", "Release the left mouse button.", [:], []),
            ("cursor_position", "Get the cursor position in screenshot pixels.", [:], []),
            ("scroll", "Scroll at the current or given screenshot coordinate. text optionally specifies modifier keys.",
             ["scroll_direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "scroll_amount": ["type": "integer", "minimum": 1, "maximum": 100], "coordinate": coordinate, "text": text], ["scroll_direction", "scroll_amount"]),
            ("type", "Type text into the focused control.", ["text": text], ["text"]),
            ("key", "Press a key or combination, e.g. Return, Tab, cmd+c; repeat optionally repeats it.", ["text": text, "repeat": ["type": "integer", "minimum": 1, "maximum": 100]], ["text"]),
            ("hold_key", "Hold a key or combination for up to 30 seconds.", ["text": text, "duration": duration], ["text", "duration"]),
            ("wait", "Wait up to 30 seconds.", ["duration": duration], ["duration"]),
        ]
        for name in ["left_click", "right_click", "middle_click", "double_click", "triple_click"] {
            definitions.append((name, "\(name.replacingOccurrences(of: "_", with: " ").capitalized) at screenshot coordinates or the current cursor. text optionally specifies modifier keys.", ["coordinate": coordinate, "text": text], []))
        }
        return definitions.map { name, description, properties, required in
            let exposed = "computer__\(name)"
            return CLIToolBinding(name: exposed, originalName: name, toolset: "computer",
                                  definition: ["name": exposed, "description": description,
                                               "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]])
        }
    }
}

struct CLIToolBinding {
    let name: String
    let originalName: String
    let toolset: String?
    let definition: [String: Any]
}

private struct PendingCLITool {
    let identifier: String
    let binding: CLIToolBinding
    let result: CLIToolResultBox
    let task: Task<Void, Never>
}

private final class CLIToolResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ToolResult?
    func put(_ value: ToolResult) { lock.lock(); result = value; lock.unlock() }
    func take() -> ToolResult? { lock.lock(); defer { lock.unlock() }; defer { result = nil }; return result }
}

/// Files avoid pipe buffer deadlocks for large screenshots. Nothing is retained
/// after the turn, and even temporary input/output is accessible only to its owner.
private final class CLIWorkspace {
    let root: URL
    var requests: URL { root.appendingPathComponent("requests") }
    var output: URL { root.appendingPathComponent("output.jsonl") }
    var errorOutput: URL { root.appendingPathComponent("error.txt") }
    private var handles: [FileHandle] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for name in ["requests", "responses"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func write(_ data: Data, to name: String) throws {
        let destination = root.appendingPathComponent(name)
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func writeJSON(_ object: Any, to name: String) throws { try write(JSONSerialization.data(withJSONObject: object), to: name) }

    func process(executable: String, arguments: [String], environment: [String: String], input: URL? = nil) throws -> Process {
        try write(Data(), to: "output.jsonl")
        try write(Data(), to: "error.txt")
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errorOutput)
        handles += [out, err]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = root
        process.standardOutput = out
        process.standardError = err
        if let input {
            let handle = try FileHandle(forReadingFrom: input)
            handles.append(handle)
            process.standardInput = handle
        } else { process.standardInput = FileHandle.nullDevice }
        return process
    }

    func close() {
        for handle in handles { try? handle.close() }
        handles.removeAll()
        try? FileManager.default.removeItem(at: root)
    }
    deinit { close() }
}
