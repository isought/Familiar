import Foundation
import Testing
@testable import Familiar

@Suite
struct ClaudeCodeComputerToolsTests {
    private let enabledToolset: [[String: Any]] = [["type": "computer_toolset_20260801"]]

    @Test
    func nativeComputerActionsAreOnlyExposedWhenEnabled() throws {
        #expect(ClaudeCodeClient.toolBindings([]).isEmpty)
        let bindings = ClaudeCodeClient.toolBindings(enabledToolset)
        let click = try #require(bindings.first { $0.name == "computer__left_click" })
        #expect(click.originalName == "left_click")
        #expect(click.toolset == "computer")
        #expect(bindings.contains { $0.name == "computer__screenshot" })
    }

    @Test
    func packToolNameCannotShadowNativeComputerAction() throws {
        let scriptTool: [String: Any] = ["name": "computer__screenshot", "description": "A pack tool.",
                                        "input_schema": ["type": "object", "properties": [:]]]
        let bindings = ClaudeCodeClient.toolBindings([scriptTool] + enabledToolset)
        let native = try #require(bindings.first { $0.name == "computer__screenshot" })
        let pack = try #require(bindings.first { $0.toolset == nil })
        #expect(native.originalName == "screenshot")
        #expect(native.toolset == "computer")
        #expect(pack.originalName == "computer__screenshot")
        #expect(pack.name != native.name)
    }

    @Test
    func rejectsMalformedComputerArgumentsBeforeNativeExecution() throws {
        let bindings = ClaudeCodeClient.toolBindings(enabledToolset)
        let click = try #require(bindings.first { $0.originalName == "left_click" })
        let scroll = try #require(bindings.first { $0.originalName == "scroll" })
        let wait = try #require(bindings.first { $0.originalName == "wait" })
        let type = try #require(bindings.first { $0.originalName == "type" })

        #expect(ClaudeCodeClient.validComputerArguments(["coordinate": [120, 240]], for: click))
        #expect(!ClaudeCodeClient.validComputerArguments(["coordinate": [120]], for: click))
        #expect(!ClaudeCodeClient.validComputerArguments(["coordinate": [true, false]], for: click))
        #expect(!ClaudeCodeClient.validComputerArguments(["coordinate": [120, 240], "unexpected": "value"], for: click))
        #expect(ClaudeCodeClient.validComputerArguments(["scroll_direction": "down", "scroll_amount": 3], for: scroll))
        #expect(!ClaudeCodeClient.validComputerArguments(["scroll_direction": "sideways", "scroll_amount": 3], for: scroll))
        #expect(!ClaudeCodeClient.validComputerArguments(["scroll_direction": "down", "scroll_amount": 1_000_000], for: scroll))
        #expect(!ClaudeCodeClient.validComputerArguments(["scroll_direction": "down", "scroll_amount": true], for: scroll))
        #expect(!ClaudeCodeClient.validComputerArguments(["duration": -1], for: wait))
        #expect(!ClaudeCodeClient.validComputerArguments(["duration": 31], for: wait))
        #expect(!ClaudeCodeClient.validComputerArguments([:], for: type))
        #expect(ClaudeCodeClient.validComputerArguments(["text": "Hello"], for: type))
    }

    @Test
    @MainActor
    func cancelledNativeActionDoesNotBeginAControlSession() async {
        let outcome = await Task { @MainActor in
            let controller = ComputerController()
            controller.hudEnabled = false
            defer { controller.end() }
            withUnsafeCurrentTask { $0?.cancel() }
            let result = await controller.perform("wait", ["duration": 0])
            return (result.isError, result.content as? String, controller.active)
        }.value

        #expect(outcome.0)
        #expect(outcome.1 == "Stopped.")
        #expect(!outcome.2)
    }
}
