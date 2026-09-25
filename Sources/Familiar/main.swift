import AppKit
import SwiftUI

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// `Familiar --selftest [toolsDir]`: load tool packs, print schemas, run two scripts, exit. No UI, no API.
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

/// `Familiar --ask "question" [url] [--shot]`: headless question through the real Claude tool loop, no screenshot, no UI.
@MainActor
func runHeadlessAsk() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--ask"), i + 1 < args.count else { print("usage: --ask \"question\" [url]"); return }
    let question = args[i + 1]
    let url = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : "https://expenses.internal.example.com/reports/new"
    let config = Config.load()
    guard let key = config.resolvedApiKey else { print("no API key"); return }
    let runner = ScriptRunner(config: config)
    let registry = ToolRegistry(root: config.resolvedToolsDir, runner: runner)
    await registry.reload()
    let title = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? (url.contains("4310") ? "Waxwing" : "New Report - Concur")
    let ctx = ScreenContext(appName: "Google Chrome", bundleID: "com.google.Chrome", windowTitle: title, url: url, focused: nil, timestamp: Date())
    let sel = registry.select(for: ctx)
    let text = Prompt.context(ctx, recent: []) + Prompt.toolPacks(active: sel.active, global: sel.global, others: sel.others, stuffLimit: config.docsStuffLimitChars)
        + Prompt.notes(onTarget: [], elsewhere: registry.notes(for: ctx)) + "\n## Question\n\(question)\n"
    var tools = (sel.active + sel.global).flatMap(\.scripts).map(\.definition) + BuiltinTools.definitions
    // --control: expose the computer toolset (no HUD in headless mode). Only meaningful when the user asked for it.
    let controlOn = args.contains("--control")
    let control = ComputerController()
    control.hudEnabled = false
    control.maxLongEdge = config.maxImageLongEdge
    control.onCaption = { print("  [control] \($0)") }
    if controlOn { tools += [ComputerController.findDefinition, ComputerController.toolsetDefinition] }
    var content: [[String: Any]] = []
    if args.contains("--shot") {
        do {
            let raw = try await ScreenCapture.captureDisplay()
            if let shot = ScreenCapture.encode(ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)) {
                content.append(["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]])
                print("screenshot: \(shot.width)x\(shot.height) \(shot.sizeKB)KB")
            }
        } catch { print("screenshot failed: \(error.localizedDescription)") }
    }
    content.append(["type": "text", "text": text])
    var messages: [[String: Any]] = [["role": "user", "content": content]]
    let client = ClaudeClient(config: config, apiKey: key)
    client.maxToolRounds = controlOn ? 40 : 8
    print("context: \(ctx.summaryLine)\nactive packs: \(sel.active.map(\.dirName)) tools: \(tools.count) notes on scene: \(registry.notes(for: ctx).count)\n")
    defer { control.end() }
    do {
        let system = Prompt.system + (controlOn ? Prompt.control : "")
        let reply = try await client.converse(system: system, tools: tools, messages: &messages, executor: { name, input, toolset in
            if toolset == "computer" { return await control.perform(name, input) }
            if name == "find_on_screen" { return control.find(input["query"] as? String ?? "") }
            if name == "look_at_screen" {
                do {
                    let raw = try await ScreenCapture.captureDisplay()
                    guard let shot = ScreenCapture.encode(ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)) else { return .text("encode failed", isError: true) }
                    print("  [look_at_screen \(shot.width)x\(shot.height)]")
                    return .blocks([["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]]])
                } catch { return .text(error.localizedDescription, isError: true) }
            }
            if BuiltinTools.names.contains(name) { return BuiltinTools.execute(name, input, root: registry.root) }
            guard let s = registry.script(named: name) else { return .text("unknown tool", isError: true) }
            do { return .text(try await runner.run(s, args: input, context: ctx)) } catch { return .text(error.localizedDescription, isError: true) }
        }, onStatus: { print("  [\($0)]") })
        let (answer, sugg) = Assistant.splitSuggestions(reply.text)
        print("\n--- reply ---\n\(answer)\n--- suggestions: \(sugg)\n--- usage: \(reply.inputTokens) in, \(reply.outputTokens) out, cache read \(reply.cacheRead), \(reply.toolCalls) tool calls")
    } catch { print("FAILED: \(error.localizedDescription)") }
}

/// `Familiar --render-mascot <dir>`: render every mascot mood at 256pt and 48pt (@2x PNG), a charging variant, gaze samples,
/// contact sheets (light at 256/48/32/24, dark at 48/32, and the 24pt card-header row), the quill cursor as a vector at 4x
/// with its hotspot marked, and `icon-1024.png` (the idle note at 512pt @2x, for the app icon), then exit.
/// Used to eyeball the character without launching the app.
@MainActor
func runRenderMascot() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-mascot"), i + 1 < args.count else { print("usage: --render-mascot <dir> [--style innocent|sharp]"); exit(2) }
    if let si = args.firstIndex(of: "--style"), si + 1 < args.count, let st = MascotStyle(rawValue: args[si + 1]) { MascotStyle.current = st }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let paper = Color(red: 0.98, green: 0.975, blue: 0.96)
    let dark = Color(white: 0.16)

    func save(_ cg: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("encode failed: \(name)"); return }
        do { try data.write(to: dir.appendingPathComponent(name)); print("wrote \(name) \(cg.width)x\(cg.height)") }
        catch { print("write failed: \(name): \(error)") }
    }
    func render<V: View>(_ v: V, _ name: String, scale: CGFloat = 2) {
        let r = ImageRenderer(content: v)
        r.scale = scale
        guard let cg = r.cgImage else { print("render failed: \(name)"); return }
        save(cg, name)
    }
    func mascot(_ mood: MascotMood, _ size: CGFloat, charge: CGFloat = 0, lookAt: CGPoint? = nil, on bg: Color = paper) -> some View {
        MascotView(mood: mood, lookAt: lookAt, charge: charge, size: size, animated: false)
            .padding(size * 0.14)
            .background(bg)
    }

    for mood in MascotMood.allCases {
        render(mascot(mood, 256), "\(mood.rawValue)-256.png")
        render(mascot(mood, 48), "\(mood.rawValue)-48.png")
    }
    render(mascot(.charging, 256, charge: 0.5), "charging-0.5-256.png")
    render(mascot(.charging, 48, charge: 0.5), "charging-0.5-48.png")
    // gaze: the pupils follow a pointer up-right (idle) and down-right (curious), showing the sclera crescent
    render(mascot(.idle, 256, lookAt: CGPoint(x: 0.9, y: -0.4)), "idle-look-256.png")
    render(mascot(.curious, 256, lookAt: CGPoint(x: 0.7, y: 0.6)), "curious-look-256.png")
    render(mascot(.curious, 48, lookAt: CGPoint(x: 0.7, y: 0.6)), "curious-look-48.png")
    // the app icon source: idle in a 512pt frame @2x = 1024px on a transparent background, with a little margin around the note
    render(MascotView(mood: .idle, size: 480, animated: false).frame(width: 512, height: 512), "icon-1024.png")

    // contact sheet: every mood at 160, 48, 32 and 24 (the card header), plus 48 and 32 on a dark bubble background
    func row(_ mood: MascotMood, sizes: [CGFloat], darkSizes: [CGFloat]) -> some View {
        HStack(spacing: 16) {
            ForEach(sizes, id: \.self) { sz in
                MascotView(mood: mood, charge: mood == .charging ? 0.6 : 0, size: sz, animated: false).frame(width: sz * 1.3, height: sz * 1.3)
            }
            ForEach(darkSizes, id: \.self) { sz in
                MascotView(mood: mood, charge: mood == .charging ? 0.6 : 0, size: sz, animated: false).frame(width: sz * 1.3, height: sz * 1.3)
                    .background(dark, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(mood.rawValue).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
        }
    }
    let sheet = VStack(spacing: 12) {
        ForEach(MascotMood.allCases, id: \.rawValue) { mood in row(mood, sizes: [160, 48, 32, 24], darkSizes: [48, 32]) }
    }.padding(16).background(paper)
    render(sheet, "sheet.png")
    // the tiny sizes on their own, at 1x and 2x, as the card header (24-28pt, no decorations) will show them
    let tiny = HStack(spacing: 14) {
        ForEach(MascotMood.allCases, id: \.rawValue) { mood in
            VStack(spacing: 6) {
                MascotView(mood: mood, size: 24, animated: false, decorations: false).frame(width: 32, height: 32)
                MascotView(mood: mood, size: 28, animated: false, decorations: false).frame(width: 36, height: 36)
                MascotView(mood: mood, size: 48, animated: false).frame(width: 60, height: 60).background(dark, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }.padding(12).background(paper)
    render(tiny, "sheet-24.png", scale: 1)
    render(tiny, "sheet-24@2x.png")

    // the quill cursor drawn as a vector at 4x over a checkerboard, hotspot marked with a red cross
    let scale: CGFloat = 4
    let px = Int(WandCursor.size.width * scale), py = Int(WandCursor.size.height * scale)
    guard let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    let cell = 8
    for y in stride(from: 0, to: py, by: cell) { for x in stride(from: 0, to: px, by: cell) {
        ctx.setFillColor(CGColor(gray: ((x / cell + y / cell) % 2 == 0) ? 0.86 : 0.72, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
    } }
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(py)); ctx.scaleBy(x: scale, y: -scale)   // flip to the cursor's top-left origin
    WandCursor.draw(in: ctx)
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9)); ctx.setLineWidth(1)
    let hx = WandCursor.hotSpot.x * scale, hy = CGFloat(py) - WandCursor.hotSpot.y * scale   // CG context is bottom-left; hotspot is top-left based
    ctx.move(to: CGPoint(x: hx - 6, y: hy)); ctx.addLine(to: CGPoint(x: hx + 6, y: hy))
    ctx.move(to: CGPoint(x: hx, y: hy - 6)); ctx.addLine(to: CGPoint(x: hx, y: hy + 6)); ctx.strokePath()
    if let out = ctx.makeImage() { save(out, "quill.png") }
    // and the real cursor image at 1x on white, gray, black and blue, as the pointer will actually appear
    let img = WandCursor.cursor.image
    let strip = HStack(spacing: 24) {
        ForEach([Color.white, Color(white: 0.5), Color(white: 0.12), Color.blue], id: \.self) { bg in
            Image(nsImage: img).interpolation(.none).frame(width: 60, height: 60).background(bg)
        }
    }.padding(8).background(Color(white: 0.9))
    render(strip, "quill-1x.png")
    exit(0)
}

/// `Familiar --render-card <dir>`: render the expanded chat card (the sticky-note pad) with a sample conversation at the
/// default 400x540 and the large 560x760, @2x, plus a dark-appearance variant of the default size, then exit.
/// Files: pad-400.png, pad-560.png, pad-400-dark.png. Used to eyeball the pad without launching the app.
@MainActor
func runRenderCard() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-card"), i + 1 < args.count else { print("usage: --render-card <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var config = Config()
    config.apiKey = "render-only"   // so the footer shows the status line instead of the no-key button; nothing is sent
    let state = Assistant(config: config, watcher: ContextWatcher(),
                          registry: ToolRegistry(root: FileManager.default.temporaryDirectory, runner: ScriptRunner(config: config)))
    state.expanded = true
    state.contextLine = "Google Chrome · New Report - Concur"
    state.transcript = [
        ChatMessage(role: .wand, text: "Cost Center (dropdown, empty)"),
        ChatMessage(role: .note, text: "Pick the one ending in your department code, not the project one, or Finance bounces it.", meta: "Priya · 2026-09-18", warning: true),
        ChatMessage(role: .assistant, text: """
            That's the **Cost Center** field: it tells Finance which team's budget pays for this report. It's required, so the form won't submit while it's empty.
            To fill it:
            1. Click the dropdown and start typing your team name — the list filters as you type.
            2. Pick the entry that ends in your department code (yours is usually 4310).
            3. If you don't see your team, choose "Other" and add a line in Comments.
            If this report is for a client project, use the project's cost center instead of your own.
            """),
        ChatMessage(role: .user, text: "how do I split this across two cost centers"),
        ChatMessage(role: .assistant, text: """
            You can't split at the report level, but you can per line item.
            Open an expense line, click **Allocate** (bottom of the line editor), then add a second row and set a percentage or an amount for each cost center. The two rows must add up to 100%.
            Do that for every line you want shared; the rest stays on the report's default cost center.
            """),
        ChatMessage(role: .error, text: "Waxwing API rejected the request (401). Check the API key in Settings and try again."),
    ]
    state.suggestions = ["Why is it required?", "Fill it for me", "Show my reports"]
    state.busy = false
    state.status = "3,652 in · 312 out · 2 tool calls · 6.1s"

    // ImageRenderer only draws pure SwiftUI; the card's ScrollView, TextField, buttons and Menu are AppKit-backed and come
    // out as placeholders. So the card is hosted in an off-screen window and its view tree is drawn into a 2x bitmap.
    func render(_ size: NSSize, dark: Bool, _ name: String) {
        state.cardSize = size
        let view = BubbleView(state: state)
            .environment(\.padStatic, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let SwiftUI lay the lazy stack out and scroll to the newest note
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { print("rep failed: \(name)"); return }
        rep.size = size   // points; twice as many pixels = @2x
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let cg = rep.cgImage else { print("render failed: \(name)"); return }
        guard let data = rep.representation(using: .png, properties: [:]) else { print("encode failed: \(name)"); return }
        do { try data.write(to: dir.appendingPathComponent(name)); print("wrote \(name) \(cg.width)x\(cg.height)") }
        catch { print("write failed: \(name): \(error)") }
    }
    print("heading font: \(HandFont.family ?? "system rounded")")
    render(BubblePanel.defaultExpandedSize, dark: false, "pad-400.png")
    render(BubblePanel.largeExpandedSize, dark: false, "pad-560.png")
    render(BubblePanel.defaultExpandedSize, dark: true, "pad-400-dark.png")
    if args.contains("--states") {   // extra checks: the empty pad, and a pick being written up
        let full = state.transcript, sugg = state.suggestions
        state.transcript = []; state.suggestions = []; state.status = ""
        render(BubblePanel.defaultExpandedSize, dark: false, "pad-400-empty.png")
        state.transcript = Array(full.prefix(3)); state.busy = true; state.status = "Reading the page…"
        render(BubblePanel.defaultExpandedSize, dark: false, "pad-400-busy.png")
        state.transcript = full; state.suggestions = sugg; state.busy = false
    }
    exit(0)
}

/// `Familiar --render-pen <dir>`: the pen overlay over a fake window, with two stickers (one open) and the note editor,
/// drawn into a PNG. For eyeballing the paper without a mouse.
@MainActor
func runRenderPen() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-pen"), i + 1 < args.count else { print("usage: --render-pen <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let size = NSSize(width: 1100, height: 720)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor

    // a fake page: a title, a toolbar of buttons, a form and a table, so the stickers have something to stick to
    let controls: [(String, NSRect)] = [("Save page", NSRect(x: 900, y: 640, width: 96, height: 28)), ("Update", NSRect(x: 796, y: 640, width: 92, height: 28)),
                                        ("Cost Center", NSRect(x: 80, y: 500, width: 320, height: 30)), ("Amount", NSRect(x: 80, y: 430, width: 200, height: 30)),
                                        ("Submit report", NSRect(x: 80, y: 360, width: 130, height: 30))]
    for (label, r) in controls {
        let v = NSView(frame: r); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.cgColor; v.layer?.cornerRadius = 6; v.layer?.borderWidth = 1; v.layer?.borderColor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
        let t = NSTextField(labelWithString: label); t.font = NSFont.systemFont(ofSize: 13); t.textColor = NSColor(calibratedWhite: 0.25, alpha: 1); t.sizeToFit()
        t.frame.origin = NSPoint(x: 10, y: (r.height - t.frame.height) / 2); v.addSubview(t)
        container.addSubview(v)
    }
    let table = NSView(frame: NSRect(x: 480, y: 300, width: 520, height: 260)); table.wantsLayer = true
    table.layer?.backgroundColor = NSColor.white.cgColor; table.layer?.borderWidth = 1; table.layer?.borderColor = NSColor(calibratedWhite: 0.8, alpha: 1).cgColor
    for row in 0..<6 {
        let l = NSView(frame: NSRect(x: 0, y: CGFloat(row) * 40, width: 520, height: 1)); l.wantsLayer = true; l.layer?.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 1).cgColor; table.addSubview(l)
    }
    container.addSubview(table)
    let title = NSTextField(labelWithString: "Expense report · September"); title.font = NSFont.systemFont(ofSize: 22, weight: .semibold); title.sizeToFit(); title.frame.origin = NSPoint(x: 80, y: 640); container.addSubview(title)

    let controller = WandController()
    let view = WandView(frame: NSRect(origin: .zero, size: size), controller: controller, screen: NSScreen.main ?? NSScreen.screens[0])
    container.addSubview(view)
    window.contentView = container

    var a1 = NoteStore.sceneAnchor(bundleID: "com.google.Chrome", windowTitle: "Concur", url: "https://expenses.internal.example.com/reports/new")
    a1.role = "AXPopUpButton"; a1.label = "Cost Center"
    var a2 = a1; a2.role = "AXButton"; a2.label = "Submit report"
    var a3 = a1; a3.role = nil; a3.label = nil; a3.rect = NoteAnchor.fractions(of: table.frame, in: container.frame)
    let n1 = StickyNote(id: "n1", anchor: a1, kind: "warning", text: "Pick the one ending in your department code, not the project one, or Finance bounces it a week later.", by: "Priya", at: "2026-09-18", confirmed: "2026-09-18")
    let n2 = StickyNote(id: "n2", anchor: a2, kind: "tip", text: "Submitting after 3pm on Friday means it waits until Tuesday's batch.", by: "Tom", at: "2026-08-30", confirmed: "2026-09-12")
    let n3 = StickyNote(id: "n3", anchor: a3, kind: "tip", text: "Filters up top apply to this table only, the totals below ignore them.", by: "david", at: "2026-09-24", confirmed: "2026-09-24")
    view.showStickers([.init(note: n1, frame: controls[2].1), .init(note: n2, frame: controls[4].1), .init(note: n3, frame: table.frame)])
    view.setExpanded("n1", true)
    view.present(anchor: a2, at: controls[1].1, existing: nil)   // the editor open on "Update"
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { print("rep failed"); exit(1) }
    rep.size = size
    container.cacheDisplay(in: container.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { print("encode failed"); exit(1) }
    do { try data.write(to: dir.appendingPathComponent("pen.png")); print("wrote pen.png \(rep.pixelsWide)x\(rep.pixelsHigh)") }
    catch { print("write failed: \(error)"); exit(1) }
    exit(0)
}

/// `Familiar --record-synthetic <dir>`: a recording from the current screen without a person: 3 full frames a second
/// apart plus 3 crops around the mouse with fake click labels, in the real events.json / meta.json format.
/// Needs Screen Recording, so run the bundle binary (build/Familiar.app/Contents/MacOS/Familiar).
@MainActor
func runRecordSynthetic() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--record-synthetic"), i + 1 < args.count else { print("usage: --record-synthetic <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    let config = Config.load()
    let recorder = WatchRecorder(config: config, watcher: ContextWatcher())
    do {
        let rec = try await recorder.recordSynthetic(into: dir)
        print("recorded \(rec.events.count) events, \(rec.meta.clicks) clicks, \(rec.meta.frames) frames into \(rec.dir.path)")
        for e in rec.events { print("  " + WatchSummarizer.line(e) + (e.crop.map { "  [\($0)]" } ?? "") + (e.full.map { "  [\($0)]" } ?? "")) }
    } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
}

/// `Familiar --summarize-recording <dir> ["purpose"] [--tools-root <dir>] [--keep]`: writes a recording up through Claude
/// and prints the draft JSON; with --keep writes the pack into --tools-root (default: a fresh temp folder, never the real
/// tools folder unless you point there) and shows what the registry makes of it.
@MainActor
func runSummarizeRecording() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--summarize-recording"), i + 1 < args.count else {
        print("usage: --summarize-recording <dir> [\"purpose\"] [--tools-root <dir>] [--keep]"); exit(2)
    }
    let dir = URL(fileURLWithPath: args[i + 1])
    let purpose = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : nil
    let toolsRoot = args.firstIndex(of: "--tools-root").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("familiar-tools-\(Int(Date().timeIntervalSince1970))")
    let config = Config.load()
    guard let key = config.resolvedApiKey else { print("no API key"); exit(1) }
    do {
        let rec = try Recording.load(dir)
        let picks = WatchSummarizer.selectImages(rec, max: config.watchMaxImages)
        print("recording: \(rec.events.count) events, \(rec.meta.clicks) clicks, hosts \(rec.meta.hosts), \(picks.count) images to send\n")
        let draft = try await WatchSummarizer.summarize(rec, purpose: purpose, config: config, apiKey: key, onStatus: { print("  [\($0)]") })
        print("--- draft (parsed: \(draft.parsed)) ---\n\(draft.prettyJSON)\n")
        if args.contains("--keep") {
            guard draft.parsed else { print("not kept: the draft could not be parsed"); exit(1) }
            let files = try PackWriter.write(draft, root: toolsRoot)
            print("--- kept in \(toolsRoot.path) ---")
            for f in files { print("  \(f.path.replacingOccurrences(of: toolsRoot.path + "/", with: ""))") }
            let registry = ToolRegistry(root: toolsRoot, runner: ScriptRunner(config: config))
            await registry.reload()
            for p in registry.packs {
                print("registry: [\(p.dirName)] \(p.name) — \(p.description)\n  match: urls=\(p.match.urls) bundles=\(p.match.bundles) titles=\(p.match.titles)\n  docs: \(p.docs.map(\.relPath))")
            }
        }
    } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
}

if CommandLine.arguments.contains("--record-synthetic") {
    Task { @MainActor in
        await runRecordSynthetic()
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--summarize-recording") {
    Task { @MainActor in
        await runSummarizeRecording()
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--render-mascot") {
    MainActor.assumeIsolated { runRenderMascot() }
} else if CommandLine.arguments.contains("--render-card") {
    MainActor.assumeIsolated { runRenderCard() }
} else if CommandLine.arguments.contains("--render-pen") {
    MainActor.assumeIsolated { runRenderPen() }
} else if CommandLine.arguments.contains("--ask") {
    Task { @MainActor in
        await runHeadlessAsk()
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--selftest") {
    Task { @MainActor in
        await runSelfTest()
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated { runApp() }
}
