import Foundation

struct MatchRules {
    var urls: [String] = []
    var bundles: [String] = []
    var titles: [String] = []
    var isEmpty: Bool { urls.isEmpty && bundles.isEmpty && titles.isEmpty }

    func matches(_ ctx: ScreenContext) -> Bool {
        if let u = ctx.url, urls.contains(where: { Self.match($0, u) }) { return true }
        if bundles.contains(where: { Self.match($0, ctx.bundleID) }) { return true }
        if titles.contains(where: { Self.match($0, ctx.windowTitle) }) { return true }
        return false
    }

    /// `/regex/` matches as a case-insensitive regex, anything else as a case-insensitive substring.
    static func match(_ pattern: String, _ s: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !s.isEmpty else { return false }
        if p.count > 2, p.hasPrefix("/"), p.hasSuffix("/") {
            let body = String(p.dropFirst().dropLast())
            return s.range(of: body, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return s.range(of: p, options: .caseInsensitive) != nil
    }
}

struct DocFile {
    let relPath: String   // relative to the tools root, e.g. "expenses/docs/expense-reports.md"
    let text: String
}

struct ScriptTool {
    let id: String        // API tool name, e.g. "expenses__report_status"
    let packDir: String
    let fileName: String
    let path: URL
    var description: String
    var inputSchema: [String: Any]
    var dependencies: [String]

    var definition: [String: Any] {
        ["name": id, "description": "[\(packDir)/scripts/\(fileName)] \(description)", "input_schema": inputSchema]
    }
}

final class ToolPack {
    let dirName: String
    let dir: URL
    var name: String
    var description: String
    var match = MatchRules()
    var requires: [String] = []     // env var names the scripts need (secrets from the Keychain)
    var body = ""
    var docs: [DocFile] = []
    var scripts: [ScriptTool] = []
    var isGlobal: Bool { match.isEmpty }

    init(dirName: String, dir: URL) {
        self.dirName = dirName
        self.dir = dir
        self.name = dirName
        self.description = ""
    }
}

/// `~/.familiar/tools/<pack>/{SKILL.md, docs/**, scripts/*.py}`
@MainActor
final class ToolRegistry {
    let root: URL
    let runner: ScriptRunner
    private(set) var packs: [ToolPack] = []
    private(set) var lastError: String?

    init(root: URL, runner: ScriptRunner) {
        self.root = root
        self.runner = runner
    }

    func reload() async {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var result: [ToolPack] = []
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,   // follows symlinks
                  !dir.lastPathComponent.hasPrefix(".") else { continue }
            let pack = ToolPack(dirName: dir.lastPathComponent, dir: dir)
            if let skill = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) {
                let (fm, body) = Self.parseFrontmatter(skill)
                pack.name = fm["name"] as? String ?? pack.dirName
                pack.description = fm["description"] as? String ?? ""
                pack.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                pack.requires = Self.list(fm["requires"])
                if let m = fm["match"] as? [String: Any] {
                    pack.match.urls = Self.list(m["urls"])
                    pack.match.bundles = Self.list(m["bundles"])
                    pack.match.titles = Self.list(m["titles"])
                }
            }
            pack.docs = loadDocs(pack)
            pack.scripts = await loadScripts(pack)
            result.append(pack)
        }
        packs = result
        let scriptCount = packs.reduce(0) { $0 + $1.scripts.count }
        Log.info("tools: \(packs.count) pack(s), \(scriptCount) script(s) in \(root.path); runtime: \(runner.summary)")
    }

    private func loadDocs(_ pack: ToolPack) -> [DocFile] {
        let docsDir = pack.dir.appendingPathComponent("docs")
        guard let e = FileManager.default.enumerator(at: docsDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [DocFile] = []
        let base = docsDir.resolvingSymlinksInPath().path + "/"   // the enumerator may hand back resolved paths (/private/tmp vs /tmp)
        for case let url as URL in e {
            guard ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = pack.dirName + "/docs/" + url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")
            out.append(DocFile(relPath: rel, text: text))
        }
        return out.sorted { $0.relPath < $1.relPath }
    }

    private func loadScripts(_ pack: ToolPack) async -> [ScriptTool] {
        let dir = pack.dir.appendingPathComponent("scripts")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "py" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return [] }
        guard runner.available else {
            lastError = "Scripts found but no Python runtime (install uv)."
            return []
        }
        var out: [ScriptTool] = []
        for f in files {
            let stem = f.deletingPathExtension().lastPathComponent
            let id = Self.toolName("\(pack.dirName)__\(stem)")
            do {
                let s = try await runner.introspect(f)
                out.append(ScriptTool(id: id, packDir: pack.dirName, fileName: f.lastPathComponent, path: f,
                                      description: s.description, inputSchema: s.inputSchema, dependencies: s.dependencies))
            } catch {
                Log.info("tools: skipping \(pack.dirName)/scripts/\(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return out
    }

    /// Packs whose match rules hit the context, plus packs with no rules (always on).
    func select(for ctx: ScreenContext?) -> (active: [ToolPack], global: [ToolPack], others: [ToolPack]) {
        var active: [ToolPack] = [], global: [ToolPack] = [], others: [ToolPack] = []
        for p in packs {
            if p.isGlobal { global.append(p) }
            else if let ctx, p.match.matches(ctx) { active.append(p) }
            else { others.append(p) }
        }
        return (active, global, others)
    }

    /// Required secrets that are not in the Keychain, per pack.
    func missingRequirements(for packs: [ToolPack]) -> [(pack: ToolPack, keys: [String])] {
        packs.compactMap { p in
            let missing = p.requires.filter { !Secrets.has($0) && ProcessInfo.processInfo.environment[$0] == nil }
            return missing.isEmpty ? nil : (p, missing)
        }
    }

    func script(named id: String) -> ScriptTool? {
        for p in packs { if let s = p.scripts.first(where: { $0.id == id }) { return s } }
        return nil
    }

    // MARK: parsing helpers

    static func toolName(_ s: String) -> String {
        let cleaned = s.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : Character("_") }
        return String(String(cleaned).prefix(64))
    }

    static func list(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String, !s.isEmpty { return [s] }
        return []
    }

    /// Tiny YAML subset: `key: value`, `key:` + indented `sub: value`, lists as `[a, b]` or `- item` lines.
    static func parseFrontmatter(_ text: String) -> ([String: Any], String) {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], text) }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], text) }
        let fmLines = Array(lines[..<end])
        let body = lines[(end + 1)...].joined(separator: "\n")

        var top: [String: Any] = [:]
        var currentTop: String?
        var currentSub: String?
        for raw in fmLines {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("- ") {
                let item = scalar(String(trimmed.dropFirst(2)))
                if let t = currentTop, let s = currentSub, var nested = top[t] as? [String: Any] {
                    nested[s] = (nested[s] as? [String] ?? []) + [item]
                    top[t] = nested
                } else if let t = currentTop {
                    top[t] = (top[t] as? [String] ?? []) + [item]
                }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                currentTop = key
                currentSub = nil
                top[key] = rest.isEmpty ? [String: Any]() : value(rest)
            } else if let t = currentTop {
                var nested = top[t] as? [String: Any] ?? [:]
                nested[key] = rest.isEmpty ? [String]() : value(rest)
                top[t] = nested
                currentSub = key
            }
        }
        return (top, body)
    }

    private static func value(_ s: String) -> Any {
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = s.dropFirst().dropLast()
            return inner.split(separator: ",").map { scalar(String($0)) }.filter { !$0.isEmpty }
        }
        return scalar(s)
    }

    private static func scalar(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}
