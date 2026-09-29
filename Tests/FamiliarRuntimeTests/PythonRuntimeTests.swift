import Foundation
import Testing
@testable import FamiliarRuntime

@Suite
struct PythonRuntimeTests {
    @Test
    func packagedHelpersAndUvResolveOutsideTheRepository() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = PythonRuntime.discover(uvPath: "", resourceURL: fixture.resources,
                                             workingDirectory: fixture.unrelatedDirectory)
        #expect(runtime.uv == fixture.bundledUv.path)
        #expect(runtime.helpers == fixture.resources.appendingPathComponent("py"))

        let override = try fixture.executable("custom-uv")
        let configured = PythonRuntime.discover(uvPath: override.path, resourceURL: fixture.resources,
                                                workingDirectory: fixture.unrelatedDirectory)
        #expect(configured.uv == override.path)
        #expect(configured.helpers == runtime.helpers)

        let invalidOverride = PythonRuntime.discover(uvPath: fixture.root.appendingPathComponent("missing").path,
                                                     resourceURL: fixture.resources,
                                                     workingDirectory: fixture.unrelatedDirectory)
        #expect(invalidOverride.uv == fixture.bundledUv.path)
    }

    @Test
    func developmentHelpersResolveFromTheSuppliedWorkingDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = fixture.unrelatedDirectory.appendingPathComponent("Resources/py")
        let unbundled = PythonRuntime.discover(uvPath: fixture.bundledUv.path, resourceURL: nil,
                                               workingDirectory: fixture.unrelatedDirectory)
        #expect(unbundled.helpers == expected)

        try FileManager.default.removeItem(at: fixture.resources.appendingPathComponent("py/run_tool.py"))
        let incompleteBundle = PythonRuntime.discover(uvPath: "", resourceURL: fixture.resources,
                                                      workingDirectory: fixture.unrelatedDirectory)
        #expect(incompleteBundle.helpers == expected)
        #expect(incompleteBundle.uv == fixture.bundledUv.path)
    }

    private struct Fixture {
        let root: URL
        var resources: URL { root.appendingPathComponent("Noteling.app/Contents/Resources") }
        var bundledUv: URL { resources.appendingPathComponent("bin/uv") }
        var unrelatedDirectory: URL { root.appendingPathComponent("elsewhere") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-runtime-paths-\(UUID().uuidString)")
            do {
                for directory in [resources.appendingPathComponent("py"), bundledUv.deletingLastPathComponent(), unrelatedDirectory] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                try Data().write(to: resources.appendingPathComponent("py/run_tool.py"))
                _ = try executable("Noteling.app/Contents/Resources/bin/uv")
            } catch {
                remove()
                throw error
            }
        }

        func executable(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
