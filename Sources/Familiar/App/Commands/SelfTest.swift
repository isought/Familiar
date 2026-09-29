import AppKit
import SwiftUI
import FamiliarContracts
import FamiliarRuntime

/// `Noteling --selftest [toolsDir]`: load tool packs, print schemas, run two scripts, exit. No UI, no API.
@MainActor
func runSelfTest() async {
    let config = Config()
    let args = CommandLine.arguments
    let root = args.count > 2 ? URL(fileURLWithPath: args[2]) : config.resolvedToolsDir
    let runner = ScriptRunner(config: config)
    print("runtime: \(runner.summary)\nhelpers: \(runner.helpers.path)\ntools root: \(root.path)")
    let registry = ToolRegistry(root: root, runner: runner)
    await registry.reload()
    for p in registry.packs {
        print("\n[\(p.dirName)] \(p.name) — \(p.description)\n  match: urls=\(p.match.urls) bundles=\(p.match.bundles) titles=\(p.match.titles) global=\(p.isGlobal)")
        for d in p.docs { print("  doc: \(d.relPath) (\(d.text.count) chars)") }
        for s in p.scripts {
            let schema = (try? JSONSerialization.data(withJSONObject: s.inputSchema)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            print("  script: \(s.id) deps=\(s.dependencies)\n    \(s.description)\n    \(schema)")
        }
    }
    let ctx = ScreenContext(appName: "Google Chrome", bundleID: "com.google.Chrome", windowTitle: "New Report - Concur",
                            url: "https://expenses.internal.example.com/reports/new", focused: nil, timestamp: Date())
    let sel = registry.select(for: ctx)
    print("\nmatch for \(ctx.summaryLine): active=\(sel.active.map(\.dirName)) global=\(sel.global.map(\.dirName)) others=\(sel.others.map(\.dirName))")
    for (id, input) in [("expenses__report_status", ["report_id": "2026-09 Client dinner"]), ("it-access__vpn_status", [:]), ("shared__fetch_page", ["url": "https://example.com"])] {
        guard let tool = registry.script(named: id) else { print("\nmissing \(id)"); continue }
        do { print("\n\(id) ->\n\(try await runner.run(tool, args: input, context: ctx))") }
        catch { print("\n\(id) FAILED: \(error.localizedDescription)") }
    }
    print("\ngrep 'meal' ->\n\(BuiltinTools.execute("grep", ["pattern": "meal"], root: root).content)")
    print("\nsplitSuggestions -> \(Assistant.splitSuggestions("Answer line.\n\nSuggestions: Why is it greyed out? | Show my reports | Open the wiki"))")
    await selfTestNotes()
}

/// Notes: anchors match the scenes and controls they should, the store round-trips, and a scene without a pack gets one.
@MainActor
func selfTestNotes() async {
    var failures = 0
    func check(_ name: String, _ ok: Bool) { print("  \(ok ? "ok " : "FAIL") \(name)"); if !ok { failures += 1 } }
    print("\nnotes:")
    let web = ScreenContext(appName: "Google Chrome", bundleID: "com.google.Chrome", windowTitle: "Waxwing", url: "http://127.0.0.1:4310/?page=abc", focused: nil, timestamp: Date())
    let other = ScreenContext(appName: "Google Chrome", bundleID: "com.google.Chrome", windowTitle: "Concur", url: "https://expenses.internal.example.com/reports/new", focused: nil, timestamp: Date())
    let native = ScreenContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", windowTitle: "Untitled 3 — Edited", url: nil, focused: nil, timestamp: Date())
    var site = NoteStore.sceneAnchor(bundleID: web.bundleID, windowTitle: web.windowTitle, url: web.url)
    site.role = "AXButton"; site.label = "Save  page"
    check("site anchor is host+path", site.host == "127.0.0.1:4310" && site.path == "/" && site.bundle == nil)
    check("site anchor matches its scene", site.matchesScene(web))
    check("site anchor ignores another host", !site.matchesScene(other))
    check("label match is case/space-insensitive", site.matchesElement(role: "AXButton", label: "save page"))
    check("label match needs the role", !site.matchesElement(role: "AXLink", label: "Save page"))
    var app = NoteStore.sceneAnchor(bundleID: native.bundleID, windowTitle: native.windowTitle, url: nil)
    check("native anchor is bundle+window", app.bundle == "com.apple.TextEdit" && app.window == "Untitled 3 — Edited" && app.host == nil)
    check("native anchor matches its scene", app.matchesScene(native))
    app.window = "Untitled"
    check("window fragment matches", app.matchesScene(native))
    check("native anchor ignores a browser", !app.matchesScene(web))
    let wf = NSRect(x: 100, y: 200, width: 1000, height: 800)
    let r = NSRect(x: 600, y: 700, width: 200, height: 100)
    var region = site; region.role = nil; region.label = nil
    region.rect = NoteAnchor.fractions(of: r, in: wf)
    let back = region.screenRect(in: wf)
    check("rect anchor round-trips", region.isRegion && back.map { abs($0.minX - r.minX) < 0.5 && abs($0.minY - r.minY) < 0.5 && abs($0.width - r.width) < 0.5 && abs($0.height - r.height) < 0.5 } == true)
    check("summary reads well", site.summary == "button “Save  page” on 127.0.0.1:4310" && region.summary == "a circled spot on 127.0.0.1:4310")

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-notes-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        let dir = try NoteStore.ensurePack(for: site, appName: "Google Chrome", root: tmp)
        check("pack created for the host", dir.lastPathComponent == "127-0-0-1-4310" && FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path))
        let again = try NoteStore.ensurePack(for: site, appName: nil, root: tmp)
        check("ensurePack is idempotent", again.standardizedFileURL.path == dir.standardizedFileURL.path)
        let n1 = NoteStore.make(NoteDraft(existingID: nil, anchor: site, kind: "warning", text: "  Saves a new version every time. \n", frame: .zero), by: "david")
        let n2 = NoteStore.make(NoteDraft(existingID: nil, anchor: region, kind: "tip", text: "Filters apply to this table only.", frame: .zero), by: "david")
        try NoteStore.save([n1, n2], packDir: dir)
        let loaded = NoteStore.load(packDir: dir)
        check("store round-trips", loaded == [n1, n2] && n1.text == "Saves a new version every time." && n1.isWarning && !n1.at.isEmpty)
        let registry = ToolRegistry(root: tmp, runner: ScriptRunner(config: Config()))
        await registry.reload()
        check("registry loads notes and matches the scene", registry.notes(for: web).count == 2 && registry.notes(for: other).isEmpty)
        check("registry finds the pack holding a note", registry.pack(holding: n2.id)?.dirName == "127-0-0-1-4310")
        check("the created pack is active on its scene", registry.select(for: web).active.map(\.dirName) == ["127-0-0-1-4310"])
        try registry.removeNote(id: n1.id)
        check("remove writes through", NoteStore.load(packDir: dir).map(\.id) == [n2.id] && registry.notes(for: web).count == 1)
        let placed = WandController.place(loaded, scan: AXScan.Result(bundleID: nil, windowFrame: wf, items: [
            AXScan.Item(role: "AXButton", label: "Save page", frame: NSRect(x: 900, y: 900, width: 80, height: 24)),
            AXScan.Item(role: "AXButton", label: "Other", frame: NSRect(x: 100, y: 900, width: 80, height: 24)),
        ]))
        check("stickers land on the labelled control and the region", placed.count == 2 && placed[0].frame.minX == 900 && abs(placed[1].frame.minX - r.minX) < 0.5)
    } catch { check("store: \(error.localizedDescription)", false) }
    print(failures == 0 ? "notes: all checks passed" : "notes: \(failures) check(s) FAILED")
    if failures > 0 { exit(1) }
}
