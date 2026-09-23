import AppKit

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

if CommandLine.arguments.contains("--ask") {
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
