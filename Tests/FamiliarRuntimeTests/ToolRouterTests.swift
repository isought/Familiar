import Foundation
import Testing
import FamiliarContracts
@testable import FamiliarRuntime

@Suite
struct ToolRouterTests {
    private actor Calls {
        private var values: [String] = []
        func record(_ value: String) { values.append(value) }
        func all() -> [String] { values }
    }

    private func route(_ name: String, toolset: String? = nil, handler: @escaping ToolExecutor) -> ToolRoute {
        ToolRoute(match: .tool(name: name, toolset: toolset),
                  definition: ["name": name, "input_schema": ["type": "object", "properties": [:]]],
                  execute: handler)
    }

    private func computer(handler: @escaping ToolExecutor) -> ToolRoute {
        ToolRoute(match: .toolset("computer"), definition: ["type": "computer_toolset_20260801"], execute: handler)
    }

    @Test
    func disabledCapabilitiesAndUnexpectedNamespacesCannotReachAHandler() async throws {
        let calls = Calls()
        let router = try ToolRouter(routes: [route("read_file") { name, _, _ in
            await calls.record(name)
            return .text("read")
        }])

        for (name, toolset) in [("left_click", "computer"), ("read_file", "computer"), ("read_file", "unexpected")] {
            let result = await router.execute(name, [:], toolset: toolset)
            #expect(result.isError)
            #expect(!router.accepts(name: name, toolset: toolset))
        }
        let unknown = await router.execute("missing", [:])
        #expect(unknown.isError)
        #expect(await calls.all() == [])
        #expect(router.definitions.compactMap { $0["name"] as? String } == ["read_file"])
        #expect(router.definitions.allSatisfy { $0["type"] == nil })

        let result = await router.executor("read_file", [:], nil)
        #expect(result.content as? String == "read")
        #expect(await calls.all() == ["read_file"])
    }

    @Test
    func exactNamespacesRemainDistinctAndHandlersReceiveTheOriginalInvocation() async throws {
        let calls = Calls()
        let router = try ToolRouter(routes: [
            route("inspect") { name, input, toolset in
                await calls.record("plain:\(name):\(input["value"] as? Int ?? 0):\(toolset ?? "nil")")
                return .text("plain")
            },
            route("inspect", toolset: "documents") { name, input, toolset in
                await calls.record("scoped:\(name):\(input["value"] as? Int ?? 0):\(toolset ?? "nil")")
                return .text("scoped")
            },
            computer { name, input, toolset in
                await calls.record("native:\(name):\(input["value"] as? Int ?? 0):\(toolset ?? "nil")")
                return .text("native")
            },
        ])
        _ = await router.execute("inspect", ["value": 7])
        _ = await router.execute("inspect", ["value": 8], toolset: "documents")
        _ = await router.execute("screenshot", ["value": 9], toolset: "computer")
        #expect(await calls.all() == ["plain:inspect:7:nil", "scoped:inspect:8:documents", "native:screenshot:9:computer"])
        #expect(!router.accepts(name: "other", toolset: "documents"))
        #expect(!router.accepts(name: "screenshot"))
    }

    @Test
    func duplicateAndOverlappingRegistrationsFailInsteadOfChoosingAPriority() {
        let named = route("read_file") { _, _, _ in .text("first") }
        let duplicate = route("read_file") { _, _, _ in .text("second") }
        #expect(throws: ToolRouterError.duplicateRoute(name: "read_file", toolset: nil)) {
            try ToolRouter(routes: [named, duplicate])
        }
        let native = computer { _, _, _ in .text("native") }
        let specific = route("screenshot", toolset: "computer") { _, _, _ in .text("specific") }
        for routes in [[native, specific], [specific, native], [native, native]] {
            #expect(throws: ToolRouterError.overlappingToolset("computer")) {
                try ToolRouter(routes: routes)
            }
        }
    }

    @Test
    func advertisedExactCapabilitiesMustMatchTheirRoutes() {
        let mismatched = ToolRoute(match: .tool(name: "read_file"), definition: ["name": "write_file"]) { _, _, _ in .text("read") }
        #expect(throws: ToolRouterError.mismatchedDefinition("read_file")) {
            try ToolRouter(routes: [mismatched])
        }
    }

    @Test
    func cancellationBeforeDispatchDoesNotEnterAHandler() async throws {
        let calls = Calls()
        let router = try ToolRouter(routes: [route("write_file") { name, _, _ in
            await calls.record(name)
            return .text("written")
        }])
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let result = await router.execute("write_file", [:])
            return (result.isError, result.content as? String)
        }.value
        #expect(outcome.0)
        #expect(outcome.1 == "Stopped.")
        #expect(await calls.all() == [])

        _ = await router.execute("write_file", [:])
        #expect(await calls.all() == ["write_file"])
    }

    @Test
    func errorAndImageResultsPassThroughWithoutReencoding() async throws {
        let blocks: [[String: Any]] = [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "image-data"]]]
        let router = try ToolRouter(routes: [
            route("image") { _, _, _ in .blocks(blocks) },
            route("failure") { _, _, _ in .text("The script failed.", isError: true) },
        ])
        let image = await router.execute("image", [:])
        let returned = try #require(image.content as? [[String: Any]])
        #expect(!image.isError)
        #expect(NSArray(array: returned).isEqual(to: blocks))
        let failure = await router.execute("failure", [:])
        #expect(failure.isError)
        #expect(failure.content as? String == "The script failed.")
    }

    @Test
    func separateRunsKeepTheirCapabilitiesAndCallbacksIndependent() async throws {
        let calls = Calls()
        let first = try ToolRouter(routes: [route("inspect") { _, _, _ in
            await calls.record("first")
            return .text("first context")
        }])
        let second = try ToolRouter(routes: [
            route("inspect") { _, _, _ in
                await calls.record("second")
                return .text("second context")
            },
            computer { _, _, _ in .text("computer enabled") },
        ])
        let firstResult = await first.executor("inspect", [:], nil)
        let secondResult = await second.executor("inspect", [:], nil)
        #expect(firstResult.content as? String == "first context")
        #expect(secondResult.content as? String == "second context")
        #expect(await calls.all() == ["first", "second"])
        #expect(!first.accepts(name: "screenshot", toolset: "computer"))
        #expect(second.accepts(name: "screenshot", toolset: "computer"))
        #expect(first.definitions.count == 1)
        #expect(second.definitions.count == 2)
    }
}
