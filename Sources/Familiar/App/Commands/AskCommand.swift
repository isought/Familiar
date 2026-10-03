import AppKit
import SwiftUI
import FamiliarContracts
import FamiliarRuntime

/// `Noteling --ask "question" [url] [--shot] [--api] [--pen "what was pointed at"]`: headless question through the real
/// Claude tool loop, no screenshot, no UI. A pack that briefs the page runs its brief first, as in the app; `--pen`
/// asks as a pen pick on a control with that label instead of a typed question; `--api` uses the API key whatever the
/// config says.
@MainActor
func runHeadlessAsk() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--ask"), i + 1 < args.count else { print("usage: --ask \"question\" [url]"); return }
    let question = args[i + 1]
    let url = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : "https://expenses.internal.example.com/reports/new"
    var config = Config.load()
    if args.contains("--claude-cli") { config.connectionMode = "claudeCode" }
    if args.contains("--api") { config.connectionMode = "api" }
    guard let client = ConversationBackend.make(config: config) else {
        print(ConversationBackend.setupMessage(config: config)); exit(1)
    }
    let runner = ScriptRunner(config: config)
    let registry = ToolRegistry(root: config.resolvedToolsDir, runner: runner)
    await registry.reload()
    let title = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? (url.contains("4310") ? "Waxwing" : "New Report - Concur")
    var ctx = ScreenContext(appName: "Google Chrome", bundleID: "com.google.Chrome", windowTitle: title, url: url, focused: nil, timestamp: Date())
    // --background describes the real window it will work in, not the synthetic Chrome scene.
    let backgroundOn = args.contains("--control") && args.contains("--background")
    var backgroundTarget: TargetWindow?
    if backgroundOn, case .success(let t) = await TargetWindow.resolveFrontmost() {
        backgroundTarget = t
        ctx = ScreenContext(appName: t.appName, bundleID: t.bundleID, windowTitle: t.title, url: nil, focused: nil, timestamp: Date())
    }
    let packContext = PackContextProvider.context(for: ctx, registry: registry, docsLimit: config.docsStuffLimitChars,
                                                   includeMissingRequirements: false)
    var brief = ""
    let briefs = PageBriefs(registry: registry)
    if briefs.source(for: ctx) != nil {
        let started = Date()
        if let b = await briefs.brief(for: ctx, wait: 30) {
            brief = Prompt.brief(b)
            print("brief: \(b.script) \(b.failed ? "failed" : "ok") in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(b.text.count) chars")
        }
    }
    var ask = "\n## Question\n\(question)\n"
    if let p = args.firstIndex(of: "--pen"), p + 1 < args.count {
        let element = AXElementInfo(role: "AXStaticText", title: args[p + 1], frame: .zero)
        ask = "\n" + Prompt.wandInstruction(target: WandTarget(screenPoint: .zero, element: element, windowOwner: "Google Chrome", windowTitle: title), ctx: ctx)
    }
    let text = Prompt.context(ctx, recent: []) + packContext.promptSection + brief + ask
    // --control: expose the computer toolset (no HUD in headless mode). Only meaningful when the user asked for it.
    let controlOn = args.contains("--control")
    let control = ComputerController()
    control.hudEnabled = false
    control.ghostEnabled = false
    control.maxLongEdge = config.maxImageLongEdge
    control.preciseClicks = config.backgroundPreciseClicks
    control.virtualDisplayEnabled = config.backgroundVirtualDisplay
    control.onCaption = { print("  [control] \($0)") }
    if let target = backgroundTarget {
        print("target: \(target.appName) “\(target.title)” \(Int(target.frameCG.width))x\(Int(target.frameCG.height))pt \(target.toolkit.rawValue)")
    }
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
    let execution = ExecutionCoordinator()
    let desktop = DesktopExecutionService(control: control, activities: NativeActivityGate(), enablesPeek: false)
    let id = UUID()
    do {
        let result = try await execution.run(client: client, content: content, prepareImages: false, prepare: {
            let capture: () async -> ToolResult = {
                do {
                    let raw = try await ScreenCapture.captureDisplay()
                    guard let shot = ScreenCapture.encode(ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)) else { return .text("encode failed", isError: true) }
                    print("  [look_at_screen \(shot.width)x\(shot.height)]")
                    return .blocks([["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]]])
                } catch { return .text(error.localizedDescription, isError: true) }
            }
            let prepared: PreparedExecution
            if controlOn {
                prepared = try await desktop.prepare(id: id, registry: registry, context: ctx, background: backgroundOn,
                                                     target: backgroundTarget, lookAtScreen: capture)
            } else {
                let router = try ExecutionTools.make(registry: registry, context: ctx, control: nil,
                                                     background: false, lookAtScreen: capture)
                prepared = PreparedExecution(system: Prompt.system, router: router)
            }
            print("context: \(ctx.summaryLine)\nactive packs: \(packContext.active.map(\.dirName)) tools: \(prepared.router.definitions.count) notes on scene: \(packContext.sceneNotes.count)\n")
            return prepared
        }, stopNative: { desktop.stop(id: id) }, cleanup: { _ = desktop.finish(id: id) },
           onStatus: { print("  [\($0)]") })
        switch result.outcome {
        case .reply(let reply):
            let (answer, suggestions) = Assistant.splitSuggestions(reply.text)
            print("\n--- reply ---\n\(answer)\n--- suggestions: \(suggestions)\n--- usage: \(reply.inputTokens) in, \(reply.outputTokens) out, cache read \(reply.cacheRead), \(reply.toolCalls) tool calls")
        case .cancelled: print("Stopped.")
        case .failed(let error): throw error
        }
    } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }

}
