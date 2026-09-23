import Foundation

struct ScriptSchema {
    let description: String
    let inputSchema: [String: Any]
    let dependencies: [String]
}

struct ScriptRunnerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs Python scripts from tool packs. Prefers `uv` (inline PEP 723 deps work), falls back to system python3.
final class ScriptRunner {
    let uv: String?
    let python: String?
    let helpers: URL

    init(config: Config) {
        let fm = FileManager.default
        var candidates: [String] = []
        if !config.uvPath.isEmpty { candidates.append((config.uvPath as NSString).expandingTildeInPath) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/uv").path { candidates.append(bundled) }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        uv = candidates.first { fm.isExecutableFile(atPath: $0) }
        python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { fm.isExecutableFile(atPath: $0) }

        if let r = Bundle.main.resourceURL?.appendingPathComponent("py"), fm.fileExists(atPath: r.appendingPathComponent("run_tool.py").path) {
            helpers = r
        } else {
            // Running from the repo (swift run / selftest): Resources/py next to Package.swift
            helpers = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/py")
        }
    }

    var available: Bool { uv != nil || python != nil }
    var summary: String {
        if let uv { return "uv at \(uv)" }
        if let python { return "python3 at \(python) (no uv: scripts with dependencies will fail)" }
        return "no Python runtime found"
    }

    private func command(helper: String, script: URL, deps: [String]) -> (String, [String])? {
        let helperPath = helpers.appendingPathComponent(helper).path
        if let uv {
            var args = ["run", "--no-project", "--quiet"]
            for d in deps { args += ["--with", d] }
            args += [helperPath, script.path]
            return (uv, args)
        }
        if let python { return (python, [helperPath, script.path]) }
        return nil
    }

    func introspect(_ script: URL) async throws -> ScriptSchema {
        guard let (exe, args) = command(helper: "introspect.py", script: script, deps: []) else {
            throw ScriptRunnerError(message: "no Python runtime")
        }
        let r = try await Subprocess.run(exe, args, timeout: 120)
        guard let json = Self.lastJSONLine(r.stdout) else {
            throw ScriptRunnerError(message: "introspect failed for \(script.lastPathComponent): \(r.stderr.suffix(300))")
        }
        if let err = json["error"] as? String { throw ScriptRunnerError(message: err) }
        return ScriptSchema(description: json["description"] as? String ?? script.lastPathComponent,
                            inputSchema: json["input_schema"] as? [String: Any] ?? ["type": "object", "properties": [:]],
                            dependencies: json["dependencies"] as? [String] ?? [])
    }

    var extraEnv: [String: String] = [:]   // non-secret config env

    func run(_ tool: ScriptTool, args: [String: Any], context: ScreenContext?, secrets: [String] = []) async throws -> String {
        guard let (exe, cmdArgs) = command(helper: "run_tool.py", script: tool.path, deps: tool.dependencies) else {
            throw ScriptRunnerError(message: "no Python runtime")
        }
        let stdin = try JSONSerialization.data(withJSONObject: args)
        var env = extraEnv
        env["FAMILIAR_TOOL_DIR"] = tool.path.deletingLastPathComponent().deletingLastPathComponent().path
        for key in secrets { if let v = Secrets.get(key) { env[key] = v } }
        if let context, let d = try? JSONSerialization.data(withJSONObject: context.json), let s = String(data: d, encoding: .utf8) {
            env["FAMILIAR_CONTEXT"] = s
        }
        let started = Date()
        let r = try await Subprocess.run(exe, cmdArgs, stdin: stdin, cwd: tool.path.deletingLastPathComponent(), env: env, timeout: 90)
        Log.info("script \(tool.id) exited \(r.code) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s\(r.timedOut ? " (timed out)" : "")")
        if r.timedOut { throw ScriptRunnerError(message: "\(tool.fileName) timed out after 90s") }
        guard let json = Self.lastJSONLine(r.stdout) else {
            throw ScriptRunnerError(message: "\(tool.fileName) produced no result. stderr: \(r.stderr.suffix(500))")
        }
        if let err = json["error"] as? String {
            let tb = json["traceback"] as? String ?? ""
            throw ScriptRunnerError(message: "\(tool.fileName) failed: \(err)\n\(tb.suffix(800))")
        }
        var out: [String: Any] = ["result": json["result"] ?? NSNull()]
        if let so = json["stdout"] { out["stdout"] = so }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let s = String(decoding: data, as: UTF8.self)
        return s.count > 20_000 ? String(s.prefix(20_000)) + "\n…(truncated)" : s
    }

    static func lastJSONLine(_ s: String) -> [String: Any]? {
        for line in s.split(separator: "\n").reversed() {
            if let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
        }
        return nil
    }
}
