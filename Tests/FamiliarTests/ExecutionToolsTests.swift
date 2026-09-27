import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite
@MainActor
struct ExecutionToolsTests {
    @Test
    func backgroundScreenshotWithoutTargetDoesNotReadTheHumansDisplay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let control = ComputerController()
        control.lane = .background
        var displayCaptures = 0
        let router = try ExecutionTools.make(registry: fixture.registry(), context: nil, control: control,
                                             background: true, lookAtScreen: {
            displayCaptures += 1
            return .text("human display fixture")
        })

        let result = await router.execute("look_at_screen", [:])

        #expect(result.isError)
        #expect(displayCaptures == 0)
        #expect((result.content as? String)?.contains("No target window") == true)
        #expect(!control.active)
    }

    @Test
    func backgroundTextWithoutTargetFailsWithoutStartingControl() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let control = ComputerController()
        control.lane = .background
        let router = try ExecutionTools.make(registry: fixture.registry(), context: nil, control: control,
                                             background: true, lookAtScreen: { .text("unused") })

        let result = await router.execute("read_screen", [:])

        #expect(result.isError)
        #expect((result.content as? String)?.contains("No target window") == true)
        #expect(!control.active)
    }

    @Test
    func foregroundAndNonControlScreenshotsKeepTheirSuppliedCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let control = ComputerController()
        for (nativeControl, background) in [(control as ComputerController?, false), (nil, true)] {
            var captures = 0
            let router = try ExecutionTools.make(registry: fixture.registry(), context: nil, control: nativeControl,
                                                 background: background, lookAtScreen: {
                captures += 1
                return .text("supplied screenshot")
            })

            let result = await router.execute("look_at_screen", [:])

            #expect(!result.isError)
            #expect(result.content as? String == "supplied screenshot")
            #expect(captures == 1)
        }
        #expect(!control.active)
    }

    @Test
    func backgroundToolDescriptionsIdentifyTheTargetAndCoordinateSpace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let router = try ExecutionTools.make(registry: fixture.registry(), context: nil, control: ComputerController(),
                                             background: true, lookAtScreen: { .text("unused") })
        let screenshot = try #require(router.definitions.first { $0["name"] as? String == "look_at_screen" })
        let text = try #require(router.definitions.first { $0["name"] as? String == "read_screen" })

        #expect((screenshot["description"] as? String)?.contains("current target window") == true)
        #expect((screenshot["description"] as? String)?.contains("computer screenshot action for display coordinates") == true)
        #expect((text["description"] as? String)?.contains("current target window") == true)
    }

    @Test
    func absentControlOmitsNativeCapabilitiesInBothLanes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registry = fixture.registry()

        for background in [false, true] {
            let router = try ExecutionTools.make(registry: registry, context: nil, control: nil,
                                                 background: background, lookAtScreen: { .text("fixture") })
            let names = Set(router.definitions.compactMap { $0["name"] as? String })
            #expect(names == BuiltinTools.names)
            #expect(router.definitions.count == BuiltinTools.names.count)
            #expect(router.definitions.allSatisfy { $0["type"] == nil })
            for name in BuiltinTools.names { #expect(router.accepts(name: name)) }
            #expect(!router.accepts(name: "find_on_screen"))
            for name in ComputerController.backgroundToolNames { #expect(!router.accepts(name: name)) }
            #expect(!router.accepts(name: "left_click", toolset: "computer"))
            #expect(!router.accepts(name: "screenshot", toolset: "computer"))
        }
    }

    @Test
    func unexpectedToolsetsCannotReachFileOrScreenshotHandlers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var captureCalls = 0
        let router = try ExecutionTools.make(registry: fixture.registry(), context: nil, control: nil,
                                             background: true, lookAtScreen: {
            captureCalls += 1
            return .text("capture fixture")
        })

        for toolset in ["computer", "unexpected"] {
            let file = await router.execute("read_file", ["path": "proof.txt"], toolset: toolset)
            #expect(file.isError)
            #expect(file.content as? String == "Unknown tool read_file")
            let capture = await router.execute("look_at_screen", [:], toolset: toolset)
            #expect(capture.isError)
            #expect(capture.content as? String == "Unknown tool look_at_screen")
        }
        #expect(captureCalls == 0)

        let allowed = await router.execute("read_file", ["path": "proof.txt"])
        #expect(!allowed.isError)
        #expect(allowed.content as? String == "fixture file reached")
    }

    @Test
    func screenshotRouteForwardsTheSuppliedImageWithoutCapturing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let blocks: [[String: Any]] = [["type": "image", "source": [
            "type": "base64", "media_type": "image/png", "data": "fixture-image-payload",
        ]]]
        var captureCalls = 0
        let router = try ExecutionTools.make(registry: fixture.registry(), context: nil, control: nil,
                                             background: false, lookAtScreen: {
            captureCalls += 1
            return .blocks(blocks)
        })

        let result = await router.executor("look_at_screen", [:], nil)
        let returned = try #require(result.content as? [[String: Any]])
        #expect(!result.isError)
        #expect(captureCalls == 1)
        #expect(NSArray(array: returned).isEqual(to: blocks))
    }

    @Test
    func onlyActiveAndGlobalPackScriptsBecomeExecutableRoutes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writePack("active", match: "expense.example.test")
        try fixture.writePack("inactive", match: "other.example.test")
        try fixture.writePack("shared", match: nil)
        let registry = fixture.registry()
        await registry.reload()
        // Populate definitions after loading packs: registration needs no Python introspection or script execution.
        for pack in registry.packs {
            pack.scripts = [ScriptTool(id: "\(pack.dirName)__inspect", packDir: pack.dirName, fileName: "inspect.py",
                                      path: pack.dir.appendingPathComponent("scripts/inspect.py"),
                                      description: "Fixture inspection", inputSchema: ["type": "object", "properties": [:]],
                                      dependencies: [])]
        }
        let context = ScreenContext(appName: "Fixture Browser", bundleID: "test.browser", windowTitle: "Expense",
                                    url: "https://expense.example.test/new", focused: nil,
                                    timestamp: Date(timeIntervalSince1970: 0))
        let router = try ExecutionTools.make(registry: registry, context: context, control: nil,
                                             background: false, lookAtScreen: { .text("fixture") })
        let names = Set(router.definitions.compactMap { $0["name"] as? String })
        #expect(names == BuiltinTools.names.union(["active__inspect", "shared__inspect"]))
        #expect(router.accepts(name: "active__inspect"))
        #expect(router.accepts(name: "shared__inspect"))
        #expect(!router.accepts(name: "inactive__inspect"))
        #expect(!router.accepts(name: "active__inspect", toolset: "computer"))
    }

    @MainActor
    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-execution-tools-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                try "fixture file reached".write(to: root.appendingPathComponent("proof.txt"), atomically: true, encoding: .utf8)
            } catch {
                remove()
                throw error
            }
        }

        func registry() -> ToolRegistry { ToolRegistry(root: root, runner: ScriptRunner(config: Config())) }

        func writePack(_ name: String, match: String?) throws {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rules = match.map { "match:\n  urls: [\($0)]\n" } ?? ""
            try "---\nname: \(name)\n\(rules)---\nFixture pack\n"
                .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
