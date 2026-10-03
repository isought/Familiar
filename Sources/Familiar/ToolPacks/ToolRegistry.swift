import FamiliarContracts
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
    var irreversible: [String] = [] // control labels the background lane must confirm before pressing (SKILL.md `irreversible:`)
    var sources: [String] = []      // scripts a saved job can read through (SKILL.md `sources:`, script names without .py)
    var brief: String?              // script run ahead for the page in front, so the pen answers from it (SKILL.md `brief:`)
    var watch: String?              // script that checks one item for a watch list (SKILL.md `watch:`)
    var body = ""
    var docs: [DocFile] = []
    var scripts: [ScriptTool] = []
    var notes: [StickyNote] = []    // notes.json: what people stuck to this tool's controls with the pen
    var linked = false              // from the team's linked tools (`LinkedTools`), which only an update changes
    var isGlobal: Bool { match.isEmpty }

    init(dirName: String, dir: URL) {
        self.dirName = dirName
        self.dir = dir
        self.name = dirName
        self.description = ""
    }
}

/// `~/.noteling/tools/<pack>/{SKILL.md, docs/**, scripts/*.py}`, then the team's linked tools, in the same shape.
@MainActor
final class ToolRegistry {
    /// Your own tools folder: the only one Noteling writes packs, notes or workflows into.
    let root: URL
    /// The team's tools: a copy of the linked repository, replaced whole on each update, so never written to. A pack
    /// of your own with the same folder name is used instead of the linked one.
    var linkedRoot: URL?
    let runner: ScriptRunner
    private(set) var packs: [ToolPack] = []
    private(set) var lastError: String?
    private var reloading: Task<Void, Never>?

    init(root: URL, runner: ScriptRunner) {
        self.root = root
        self.runner = runner
    }

    /// Reloads run one after another, so the one started last is the one that counts, even when an update replaces
    /// the linked tools while an earlier reload is still reading them.
    func reload() async {
        let previous = reloading
        let next = Task { await previous?.value; await self.load() }
        reloading = next
        await next.value
    }

    private func load() async {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var result: [ToolPack] = []
        let own = Self.packFolders(in: root)
        let ownNames = Set(own.map(\.lastPathComponent))
        let linked = linkedRoot.map { Self.packFolders(in: $0) } ?? []
        for dir in linked where ownNames.contains(dir.lastPathComponent) {
            Log.info("tools: your own \(dir.lastPathComponent) is used instead of the linked one")
        }
        for (dir, isLinked) in own.map({ ($0, false) }) + linked.filter({ !ownNames.contains($0.lastPathComponent) }).map({ ($0, true) }) {
            let pack = ToolPack(dirName: dir.lastPathComponent, dir: dir)
            pack.linked = isLinked
            if let skill = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) {
                let (fm, body) = Self.parseFrontmatter(skill)
                pack.name = fm["name"] as? String ?? pack.dirName
                pack.description = fm["description"] as? String ?? ""
                pack.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                pack.requires = Self.list(fm["requires"]).filter { $0 != LinkedTools.tokenKey }   // that token is Noteling's own
                pack.irreversible = Self.list(fm["irreversible"])
                pack.sources = Self.list(fm["sources"])
                pack.brief = Self.list(fm["brief"]).first
                pack.watch = Self.list(fm["watch"]).first
                if let m = fm["match"] as? [String: Any] {
                    pack.match.urls = Self.list(m["urls"])
                    pack.match.bundles = Self.list(m["bundles"])
                    pack.match.titles = Self.list(m["titles"])
                }
            }
            pack.docs = loadDocs(pack)
            pack.scripts = await loadScripts(pack)
            pack.notes = NoteStore.load(packDir: dir)
            result.append(pack)
        }
        packs = result
        let scriptCount = packs.reduce(0) { $0 + $1.scripts.count }
        let noteCount = packs.reduce(0) { $0 + $1.notes.count }
        let linkedCount = packs.filter(\.linked).count
        let place = root.path + (linkedCount > 0 ? " and \(linkedCount) linked in \(linkedRoot?.path ?? "")" : "")
        Log.info("tools: \(packs.count) pack(s), \(scriptCount) script(s), \(noteCount) note(s) in \(place); runtime: \(runner.summary)")
    }

    /// The packs a tools folder holds: its folders (or links to one), not hidden ones, by name.
    nonisolated static func packFolders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { dir in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue   // follows symlinks
                && !dir.lastPathComponent.hasPrefix(".")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The folder in your own tools for a new pack called `name`: that name, unless only the linked tools have a pack
    /// of it. One of yours would hide theirs, so yours gets a name of its own beside it.
    func personalPackDir(for name: String) -> String {
        let fm = FileManager.default
        func linkedOnly(_ n: String) -> Bool {
            guard let linkedRoot else { return false }
            return fm.fileExists(atPath: linkedRoot.appendingPathComponent(n).path) && !fm.fileExists(atPath: root.appendingPathComponent(n).path)
        }
        guard linkedOnly(name) else { return name }
        var candidate = name + "-mine", n = 2
        while linkedOnly(candidate) { candidate = "\(name)-mine-\(n)"; n += 1 }
        return candidate
    }

    // MARK: notes

    /// Where notes are kept now; tool packs only hold notes from before it, until they are moved.
    var notesStore: NotesStore?

    /// Every note whose anchor is on the current scene: the store's, then any still kept in a pack that the store
    /// has no copy of and didn't remove (a linked pack's copy is never changed, so the store's word counts).
    func notes(for ctx: ScreenContext?) -> [StickyNote] {
        let stored = notesStore?.notes(for: ctx) ?? []
        return stored + packNotes(for: ctx).filter { notesStore?.supersedes($0.id) != true }
    }

    /// Each note once: your own packs come first, so your copy of a team note wins.
    private func packNotes(for ctx: ScreenContext?) -> [StickyNote] {
        guard let ctx else { return [] }
        var seen = Set<String>()
        return packs.flatMap { $0.notes.filter { $0.anchor.matchesScene(ctx) } }.filter { seen.insert($0.id).inserted }
    }

    func pack(holding noteID: String) -> ToolPack? {
        packs.first { $0.notes.contains { $0.id == noteID } }
    }

    /// The pack a new note belongs to: the first of your own packs whose match rules cover the note's scene, else one
    /// created for it in your own tools folder.
    func packForNote(anchor: NoteAnchor, appName: String?) async throws -> ToolPack {
        if let p = select(for: anchor.sceneContext).active.first(where: { !$0.linked }) { return p }
        let dir = try NoteStore.ensurePack(for: anchor, appName: appName, root: root,
                                           dirName: personalPackDir(for: NoteStore.packSlug(for: anchor, appName: appName)))
        await reload()
        guard let p = packs.first(where: { !$0.linked && $0.dir.lastPathComponent == dir.lastPathComponent }) else {
            throw ClaudeError(message: "Could not create a pack for the note in \(dir.path).")
        }
        return p
    }

    /// Adds or replaces a note (by id) in its pack and writes notes.json. Never in a linked pack.
    func put(_ note: StickyNote, in pack: ToolPack) throws {
        guard !pack.linked else {
            throw ClaudeError(message: "\(pack.name) comes from the team's linked tools, which Noteling doesn't change. The note wasn't saved there.")
        }
        var notes = pack.notes.filter { $0.id != note.id }
        notes.append(note)
        try NoteStore.save(notes, packDir: pack.dir)
        pack.notes = notes
    }

    /// Takes a note out of its pack. A linked pack's file stays as the team wrote it; the notes store remembers the removal.
    func removeNote(id: String) throws {
        guard let pack = pack(holding: id) else { return }
        let notes = pack.notes.filter { $0.id != id }
        if !pack.linked { try NoteStore.save(notes, packDir: pack.dir) }
        pack.notes = notes
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

    /// Scripts a saved job can read through, with the pack that holds each.
    func sourceScripts() -> [(pack: ToolPack, script: ScriptTool)] {
        packs.flatMap { pack in
            pack.scripts.filter { pack.sources.contains(($0.fileName as NSString).deletingPathExtension) }.map { (pack, $0) }
        }
    }

    /// A pack's named script (`brief:` or `watch:` in its SKILL.md), when the pack has it.
    func script(_ name: String?, in pack: ToolPack) -> ScriptTool? {
        guard let name, !name.isEmpty else { return nil }
        let stem = (name as NSString).deletingPathExtension
        return pack.scripts.first { ($0.fileName as NSString).deletingPathExtension == stem }
    }

    /// The pack that holds a script, for its required secrets.
    func pack(holdingScript id: String) -> ToolPack? {
        packs.first { $0.scripts.contains { $0.id == id } }
    }

    /// Packs that shipped before `.bundled-packs` existed: an install without one of them removed it on purpose.
    nonisolated static let earlierBundledPacks: Set<String> = ["expenses", "hr-portal", "it-access", "shared", "waxwing"]

    /// Copies bundled packs this tools folder has never been offered, so a pack added in an update reaches existing
    /// installs. Packs people edited or removed are left alone: `.bundled-packs` records what was offered before.
    @discardableResult
    nonisolated static func addMissingPacks(from bundled: URL, to root: URL) -> [String] {
        let fm = FileManager.default
        let record = root.appendingPathComponent(".bundled-packs")
        let names = ((try? fm.contentsOfDirectory(atPath: bundled.path)) ?? []).filter { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".") && fm.fileExists(atPath: bundled.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
        var offered: Set<String>
        if let text = try? String(contentsOf: record, encoding: .utf8) {
            offered = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        } else {
            offered = earlierBundledPacks.union((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        }
        var added: [String] = []
        for name in names where !offered.contains(name) {
            let target = root.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) {
                guard (try? fm.copyItem(at: bundled.appendingPathComponent(name), to: target)) != nil else { continue }
                added.append(name)
            }
            offered.insert(name)
        }
        try? (offered.sorted().joined(separator: "\n") + "\n").write(to: record, atomically: true, encoding: .utf8)
        return added
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
