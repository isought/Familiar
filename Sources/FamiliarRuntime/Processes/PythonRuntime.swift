import Foundation

/// Executables and helper directory supplied to Python-backed runtime adapters.
/// Bundle ownership stays with the app; discovery accepts its resource directory.
package struct PythonRuntime {
    package let uv: String?
    package let python: String?
    package let helpers: URL

    package init(uv: String?, python: String?, helpers: URL) {
        self.uv = uv
        self.python = python
        self.helpers = helpers
    }

    package static func discover(uvPath: String, resourceURL: URL?, workingDirectory: URL) -> PythonRuntime {
        let fm = FileManager.default
        var candidates: [String] = []
        if !uvPath.isEmpty { candidates.append((uvPath as NSString).expandingTildeInPath) }
        if let bundled = resourceURL?.appendingPathComponent("bin/uv").path { candidates.append(bundled) }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        let uv = candidates.first { fm.isExecutableFile(atPath: $0) }
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { fm.isExecutableFile(atPath: $0) }

        let helpers: URL
        if let r = resourceURL?.appendingPathComponent("py"), fm.fileExists(atPath: r.appendingPathComponent("run_tool.py").path) {
            helpers = r
        } else {
            // Running from the repo (swift run / selftest): Resources/py next to Package.swift.
            helpers = workingDirectory.appendingPathComponent("Resources/py")
        }
        return PythonRuntime(uv: uv, python: python, helpers: helpers)
    }
}
