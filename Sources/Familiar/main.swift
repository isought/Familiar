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
    let text = Prompt.context(ctx, recent: []) + Prompt.toolPacks(active: sel.active, global: sel.global, others: sel.others, stuffLimit: config.docsStuffLimitChars) + "\n## Question\n\(question)\n"
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
    print("context: \(ctx.summaryLine)\nactive packs: \(sel.active.map(\.dirName)) tools: \(tools.count)\n")
    defer { control.end() }
    do {
        let system = Prompt.system + (controlOn ? Prompt.control : "")
        let reply = try await client.converse(system: system, tools: tools, messages: &messages, executor: { name, input, toolset in
            if toolset == "computer" { return await control.perform(name, input) }
            if name == "find_on_screen" { return control.find(input["query"] as? String ?? "") }
            if BuiltinTools.names.contains(name) { return BuiltinTools.execute(name, input, root: registry.root) }
            guard let s = registry.script(named: name) else { return .text("unknown tool", isError: true) }
            do { return .text(try await runner.run(s, args: input, context: ctx)) } catch { return .text(error.localizedDescription, isError: true) }
        }, onStatus: { print("  [\($0)]") })
        let (answer, sugg) = Assistant.splitSuggestions(reply.text)
        print("\n--- reply ---\n\(answer)\n--- suggestions: \(sugg)\n--- usage: \(reply.inputTokens) in, \(reply.outputTokens) out, cache read \(reply.cacheRead), \(reply.toolCalls) tool calls")
    } catch { print("FAILED: \(error.localizedDescription)") }
}

/// `Familiar --render-mascot <dir>`: render every mascot mood at 256pt and 48pt (@2x PNG), a charging variant, a contact sheet
/// and the quill cursor, then exit. Used to eyeball the character without launching the app.
@MainActor
func runRenderMascot() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-mascot"), i + 1 < args.count else { print("usage: --render-mascot <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let paper = Color(red: 0.98, green: 0.975, blue: 0.96)

    func save(_ cg: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("encode failed: \(name)"); return }
        do { try data.write(to: dir.appendingPathComponent(name)); print("wrote \(name) \(cg.width)x\(cg.height)") }
        catch { print("write failed: \(name): \(error)") }
    }
    func render<V: View>(_ v: V, _ name: String) {
        let r = ImageRenderer(content: v)
        r.scale = 2
        guard let cg = r.cgImage else { print("render failed: \(name)"); return }
        save(cg, name)
    }
    func mascot(_ mood: MascotMood, _ size: CGFloat, charge: CGFloat = 0, lookAt: CGPoint? = nil) -> some View {
        MascotView(mood: mood, lookAt: lookAt, charge: charge, size: size, animated: false)
            .padding(size * 0.08)
            .background(paper)
    }

    for mood in MascotMood.allCases {
        render(mascot(mood, 256), "\(mood.rawValue)-256.png")
        render(mascot(mood, 48), "\(mood.rawValue)-48.png")
    }
    render(mascot(.charging, 256, charge: 0.5), "charging-0.5-256.png")
    render(mascot(.charging, 48, charge: 0.5), "charging-0.5-48.png")
    render(mascot(.idle, 256, lookAt: CGPoint(x: 0.9, y: -0.4)), "idle-look-256.png")

    // contact sheet: every mood at 256, 48 and 24 (the card header) with a 64pt dark bubble background for the small ones
    let sheet = VStack(spacing: 12) {
        ForEach(MascotMood.allCases, id: \.rawValue) { mood in
            HStack(spacing: 16) {
                MascotView(mood: mood, charge: mood == .charging ? 0.6 : 0, size: 160, animated: false).frame(width: 176, height: 176)
                ForEach([48, 32, 24] as [CGFloat], id: \.self) { sz in
                    MascotView(mood: mood, charge: mood == .charging ? 0.6 : 0, size: sz, animated: false).frame(width: sz + 16, height: sz + 16)
                }
                ForEach([48, 32] as [CGFloat], id: \.self) { sz in
                    MascotView(mood: mood, charge: mood == .charging ? 0.6 : 0, size: sz, animated: false).frame(width: sz + 16, height: sz + 16)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(mood.rawValue).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            }
        }
    }.padding(16).background(paper)
    render(sheet, "sheet.png")

    // the quill cursor at 4x over a checkerboard, hotspot marked with a red cross
    let cursor = WandCursor.cursor
    let img = cursor.image, hot = cursor.hotSpot
    let scale: CGFloat = 4
    let px = Int(img.size.width * scale), py = Int(img.size.height * scale)
    guard let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    let cell = 8
    for y in stride(from: 0, to: py, by: cell) { for x in stride(from: 0, to: px, by: cell) {
        ctx.setFillColor(CGColor(gray: ((x / cell + y / cell) % 2 == 0) ? 0.86 : 0.72, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
    } }
    if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: py))
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9)); ctx.setLineWidth(1)
    let hx = hot.x * scale, hy = CGFloat(py) - hot.y * scale   // CG context is bottom-left; hotspot is top-left based
    ctx.move(to: CGPoint(x: hx - 6, y: hy)); ctx.addLine(to: CGPoint(x: hx + 6, y: hy))
    ctx.move(to: CGPoint(x: hx, y: hy - 6)); ctx.addLine(to: CGPoint(x: hx, y: hy + 6)); ctx.strokePath()
    if let out = ctx.makeImage() { save(out, "quill.png") }
    // and at 1x/2x on white and dark, as the pointer will actually appear
    let strip = HStack(spacing: 24) {
        ForEach([Color.white, Color(white: 0.5), Color(white: 0.12), Color.blue], id: \.self) { bg in
            Image(nsImage: img).interpolation(.none).frame(width: 60, height: 60).background(bg)
        }
    }.padding(8).background(Color(white: 0.9))
    render(strip, "quill-1x.png")
    exit(0)
}

if CommandLine.arguments.contains("--render-mascot") {
    MainActor.assumeIsolated { runRenderMascot() }
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
