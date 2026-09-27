import Darwin
import Foundation
import Testing
@testable import Familiar

/// Exercises the process and MCP boundaries with a local fake CLI; no account or model requests.
@Suite(.serialized)
struct ClaudeCodeClientTests {
    @Test
    func testInheritedAPIAndProviderOverridesAreRemovedWhileNormalLoginEnvironmentRemains() {
        let overrides = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_MODEL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_MAX_OUTPUT_TOKENS", "CLAUDECODE",
        ]
        var inherited = Dictionary(uniqueKeysWithValues: overrides.map { ($0, "test-override") })
        inherited["HOME"] = "/test/user"
        inherited["PATH"] = "/test/bin"
        inherited["LANG"] = "en_US.UTF-8"

        let environment = ClaudeCodeClient.environment(inherited)

        for key in overrides { #expect(environment[key] == nil, "Inherited override would change CLI billing or provider: \(key)") }
        #expect(environment["HOME"] == "/test/user")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PATH"]?.contains("/test/bin") == true)
    }

    @Test
    func testRequestPreservesScreenshotsAndHistoryWithoutSendingAPIConfiguration() async throws {
        let fixture = try FakeClaude(script: #"""
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False,
                          "result": "The highlighted control saves the document.",
                          "usage": {"input_tokens": 10, "output_tokens": 7,
                                    "cache_read_input_tokens": 3, "cache_creation_input_tokens": 2}}))
        """#)
        defer { fixture.remove() }
        var config = fixture.config
        config.apiKey = "API-KEY-MUST-NOT-BE-SENT"
        config.apiBaseURL = "https://gateway-must-not-be-used.example.test"
        config.apiHeaders = ["X-Private": "HEADER-MUST-NOT-BE-SENT"]
        config.env = ["ANTHROPIC_API_KEY": "PACK-KEY-MUST-NOT-BE-SENT"]
        config.model = "API-MODEL-MUST-NOT-BE-SENT"
        config.claudeModel = "sonnet"
        let client = ClaudeCodeClient(config: config)
        let screenshot = "ZmFrZS1zY3JlZW5zaG90"
        var messages: [[String: Any]] = [
            ["role": "user", "content": "How do I save?"],
            ["role": "assistant", "content": [["type": "text", "text": "Use the upper control."]]],
            ["role": "user", "content": [
                ["type": "text", "text": "Do you mean this one?"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": screenshot]],
            ]],
        ]

        let reply = try await client.converse(system: "Help explain the user's screen.", tools: [], messages: &messages,
                                              executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                              onStatus: { _ in })

        #expect(reply.text == "The highlighted control saves the document.")
        #expect(reply.inputTokens == 15)
        #expect(reply.outputTokens == 7)
        #expect(reply.cacheRead == 3)
        #expect(reply.toolCalls == 0)
        let capture = try fixture.capture()
        #expect(capture["api_configuration_present"] as? Bool == false)
        let arguments = try #require(capture["args"] as? [String])
        #expect(arguments.contains("sonnet"))
        let allInput = String(decoding: try JSONSerialization.data(withJSONObject: capture), as: UTF8.self)
        for forbidden in [config.apiKey, config.apiBaseURL, "HEADER-MUST-NOT-BE-SENT", "PACK-KEY-MUST-NOT-BE-SENT", config.model] {
            #expect(!(allInput.contains(forbidden)), "CLI request leaked API configuration: \(forbidden)")
        }
        let input = try #require(capture["stdin"] as? String)
        #expect(input.contains("How do I save?"))
        #expect(input.contains("Use the upper control."))
        #expect(input.contains("Do you mean this one?"))
        let events = try input.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let blockGroups = events.compactMap { ($0?["message"] as? [String: Any])?["content"] as? [[String: Any]] }
        let blocks = try #require(blockGroups.last)
        let source = try #require(blocks.first { $0["type"] as? String == "image" }?["source"] as? [String: Any])
        #expect(source["data"] as? String == screenshot)
        #expect(source["media_type"] as? String == "image/png")
        #expect(messages.last?["role"] as? String == "assistant")
        try fixture.assertWorkingDirectoryRemoved()
    }

    @Test
    func testToolsRunThroughMCPAndPreserveImagesAndErrors() async throws {
        let fixture = try FakeClaude(script: #"""
        config_file = Path(args[args.index("--mcp-config") + 1])
        server = json.loads(config_file.read_text())["mcpServers"]["familiar"]
        bridge_env = os.environ.copy()
        bridge_env.update(server.get("env", {}))
        bridge = subprocess.Popen([server["command"], *server.get("args", [])], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=bridge_env)
        def rpc(identifier, method, params):
            bridge.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}) + "\n")
            bridge.stdin.flush()
            line = bridge.stdout.readline()
            if not line:
                raise RuntimeError("MCP bridge closed: " + bridge.stderr.read())
            return json.loads(line)
        results = {}
        try:
            results["initialize"] = rpc(1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                                         "clientInfo": {"name": "test-cli", "version": "1"}})
            results["list"] = rpc(2, "tools/list", {})
            results["image"] = rpc(3, "tools/call", {"name": "capture_region", "arguments": {"region": "toolbar"}})
            results["error"] = rpc(4, "tools/call", {"name": "unavailable_action", "arguments": {}})
            results["unknown"] = rpc(5, "tools/call", {"name": "not_registered", "arguments": {}})
            (capture_file.parent / "tool-results.json").write_text(json.dumps(results))
        finally:
            bridge.stdin.close()
            bridge.wait(timeout=10)
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False,
                          "result": "I inspected the toolbar; that action is unavailable.", "usage": {}}))
        """#)
        defer { fixture.remove() }
        let client = ClaudeCodeClient(config: fixture.config)
        let definitions: [[String: Any]] = [
            ["name": "capture_region", "description": "Capture a named region.", "input_schema": ["type": "object", "properties": ["region": ["type": "string"]]]],
            ["name": "unavailable_action", "description": "Try an unavailable action.", "input_schema": ["type": "object", "properties": [:]]],
        ]
        var invoked: [String] = []
        var messages: [[String: Any]] = [["role": "user", "content": "Inspect the toolbar."]]

        let reply = try await client.converse(system: "Use the available tools.", tools: definitions, messages: &messages,
                                              executor: { name, input, toolset in
            invoked.append(name)
            #expect(toolset == nil)
            if name == "capture_region" {
                #expect(input["region"] as? String == "toolbar")
                return .blocks([["type": "text", "text": "Toolbar screenshot"],
                                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "dG9vbC1pbWFnZQ=="]]])
            }
            return .text("Action is unavailable.", isError: true)
        }, onStatus: { _ in })

        #expect(invoked == ["capture_region", "unavailable_action"])
        #expect(reply.toolCalls == 2)
        let results = try fixture.jsonFile("tool-results.json")
        let listing = try #require((results["list"] as? [String: Any])?["result"] as? [String: Any])
        let listed = try #require(listing["tools"] as? [[String: Any]])
        #expect(Set(listed.compactMap { $0["name"] as? String }) == Set(invoked))
        let image = try #require((results["image"] as? [String: Any])?["result"] as? [String: Any])
        let imageBlocks = try #require(image["content"] as? [[String: Any]])
        #expect(imageBlocks.first?["text"] as? String == "Toolbar screenshot")
        #expect(imageBlocks.last?["type"] as? String == "image")
        #expect(imageBlocks.last?["mimeType"] as? String == "image/png")
        #expect(imageBlocks.last?["data"] as? String == "dG9vbC1pbWFnZQ==")
        for key in ["error", "unknown"] {
            let result = try #require((results[key] as? [String: Any])?["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
        }
        let allBlocks = messages.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
        #expect(allBlocks.filter { $0["type"] as? String == "tool_use" }.count == 2)
        #expect(allBlocks.filter { $0["type"] as? String == "tool_result" }.count == 2)
        #expect(allBlocks.contains { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool == true })
        try fixture.assertWorkingDirectoryRemoved()
    }

    @Test
    func testFailedCLIRequestSurfacesActionableErrorAndCleansUp() async throws {
        let fixture = try FakeClaude(script: #"""
        print("Claude Code test authentication expired; run claude auth login.", file=sys.stderr)
        sys.exit(17)
        """#)
        defer { fixture.remove() }
        let client = ClaudeCodeClient(config: fixture.config)
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        do {
            _ = try await client.converse(system: "Test", tools: [], messages: &messages,
                                          executor: { _, _, _ in .text("unexpected") }, onStatus: { _ in })
            Issue.record("A failed process must not produce a successful reply")
        } catch {
            #expect(error.localizedDescription.contains("login"), "\(error.localizedDescription)")
        }
        #expect(messages.count == 1)
        try fixture.assertWorkingDirectoryRemoved()
    }

    @Test
    func testRequestTimeoutTerminatesCLIAndRemovesTemporaryData() async throws {
        let fixture = try FakeClaude(script: "signal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(30)")
        defer { fixture.remove() }
        let client = ClaudeCodeClient(config: fixture.config)
        client.requestTimeout = 1
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        let started = Date()
        do {
            _ = try await client.converse(system: "Test", tools: [], messages: &messages,
                                          executor: { _, _, _ in .text("unexpected") }, onStatus: { _ in })
            Issue.record("A timed out process must not succeed")
        } catch {
            #expect(error.localizedDescription.lowercased().contains("timed out"), "\(error.localizedDescription)")
        }
        #expect(Date().timeIntervalSince(started) < 5)
        try fixture.assertWorkingDirectoryRemoved()
        try await fixture.assertProcessTerminated()
    }

    @Test
    func testCLIStructuredErrorIsNotMistakenForAnAnswer() async throws {
        let fixture = try FakeClaude(script: #"""
        print(json.dumps({"type": "result", "subtype": "error_during_execution", "is_error": True,
                          "result": "Usage limit reached for this account.", "usage": {}}))
        """#)
        defer { fixture.remove() }
        let client = ClaudeCodeClient(config: fixture.config)
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        do {
            _ = try await client.converse(system: "Test", tools: [], messages: &messages,
                                          executor: { _, _, _ in .text("unexpected") }, onStatus: { _ in })
            Issue.record("A CLI error result must not become an assistant answer")
        } catch {
            #expect(error.localizedDescription.lowercased().contains("usage limit"), "\(error.localizedDescription)")
        }
        #expect(messages.count == 1)
        try fixture.assertWorkingDirectoryRemoved()
    }

    @Test
    func testIncompleteStreamIsReportedAndCleanedUp() async throws {
        let fixture = try FakeClaude(script: #"""
        print(json.dumps({"type": "system", "subtype": "init", "session_id": "test-session"}))
        """#)
        defer { fixture.remove() }
        let client = ClaudeCodeClient(config: fixture.config)
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        do {
            _ = try await client.converse(system: "Test", tools: [], messages: &messages,
                                          executor: { _, _, _ in .text("unexpected") }, onStatus: { _ in })
            Issue.record("An incomplete stream must not silently produce an empty answer")
        } catch {
            #expect(!(error.localizedDescription.isEmpty))
        }
        #expect(messages.count == 1)
        try fixture.assertWorkingDirectoryRemoved()
        try await fixture.assertProcessTerminated()
    }

    @Test
    func testCancellationTerminatesCLIAndRemovesTemporaryData() async throws {
        let fixture = try FakeClaude(script: "time.sleep(30)")
        defer { fixture.remove() }
        let client = ClaudeCodeClient(config: fixture.config)
        let task = Task {
            var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
            return try await client.converse(system: "Test", tools: [], messages: &messages,
                                             executor: { _, _, _ in .text("unexpected") }, onStatus: { _ in })
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: fixture.captureFile.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.captureFile.path), "Fake CLI never started")
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled request must not succeed")
        } catch {
            #expect(error is CancellationError || error.localizedDescription.lowercased().contains("cancel"), "\(error.localizedDescription)")
        }
        try fixture.assertWorkingDirectoryRemoved()
        try await fixture.assertProcessTerminated()
    }
}

private struct FakeClaude {
    let directory: URL
    let executable: URL
    var captureFile: URL { directory.appendingPathComponent("capture.json") }
    var config: Config {
        var config = Config()
        config.connectionMode = "claudeCode"
        config.claudePath = executable.path
        return config
    }

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-tests-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("fake claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pathLiteral = String(decoding: try JSONSerialization.data(withJSONObject: [directory.appendingPathComponent("capture.json").path], options: [.withoutEscapingSlashes]), as: UTF8.self)
        let program = """
        #!/usr/bin/python3
        import json, os, signal, subprocess, sys, time
        from pathlib import Path
        capture_file = Path(\(pathLiteral)[0])
        args = sys.argv[1:]
        request = sys.stdin.read()
        forbidden_values = ["API-KEY-MUST-NOT-BE-SENT", "PACK-KEY-MUST-NOT-BE-SENT", "HEADER-MUST-NOT-BE-SENT",
                            "https://gateway-must-not-be-used.example.test", "API-MODEL-MUST-NOT-BE-SENT"]
        has_api_configuration = any(secret in value for secret in forbidden_values for value in os.environ.values())
        capture_file.write_text(json.dumps({"args": args, "stdin": request, "cwd": os.getcwd(), "pid": os.getpid(),
                                          "api_configuration_present": has_api_configuration}))
        \(script)
        """
        try Data(program.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func capture() throws -> [String: Any] { try jsonFile("capture.json") }

    func jsonFile(_ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as? [String: Any])
    }

    func assertWorkingDirectoryRemoved(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let workingDirectory = try #require(try capture()["cwd"] as? String, sourceLocation: sourceLocation)
        #expect(!(FileManager.default.fileExists(atPath: workingDirectory)), "Request data was left behind at \(workingDirectory)", sourceLocation: sourceLocation)
    }

    func assertProcessTerminated(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let pid = pid_t(try #require(try capture()["pid"] as? Int, sourceLocation: sourceLocation))
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "The CLI process continued after cancellation or timeout.", sourceLocation: sourceLocation)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
