import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case user, wand, assistant, error }
    let id = UUID()
    let role: Role
    let text: String
}

@MainActor
final class Assistant: ObservableObject {
    @Published var expanded = false
    @Published var question = ""
    @Published var transcript: [ChatMessage] = []
    @Published var busy = false
    @Published var status = ""
    @Published var contextLine = "Watching…"
    @Published var suggestions: [String] = []

    var config: Config
    let watcher: ContextWatcher
    let registry: ToolRegistry
    var onStartWand: (() -> Void)?
    var onHideBubble: (() -> Void)?
    enum DragPhase { case moved, ended }
    var onDragBubble: ((DragPhase) -> Void)?   // the app moves the panel using the global mouse position
    var onOpenSettings: (() -> Void)?
    var onPoke: (() -> Void)?             // single click on the note: reaction only, plus a first-time hint

    private var client: ClaudeClient?
    private var apiMessages: [[String: Any]] = []
    private var lastCapture: (at: Date, scene: ScreenContext?)?

    init(config: Config, watcher: ContextWatcher, registry: ToolRegistry) {
        self.config = config
        self.watcher = watcher
        self.registry = registry
        if let key = config.resolvedApiKey { client = ClaudeClient(config: config, apiKey: key) }
    }

    var hasApiKey: Bool { client != nil }

    func clearConversation() {
        transcript.removeAll()
        apiMessages.removeAll()
        suggestions.removeAll()
        status = ""
        lastCapture = nil
    }

    func startWand() {
        guard !busy else { return }
        onStartWand?()
    }

    func askSuggestion(_ s: String) {
        question = s
        ask()
    }

    /// Typed question. Always attaches a fresh screenshot as context (the chat card itself is excluded from the capture),
    /// unless `screenshotReuseSeconds` allows reusing the last one for a quick follow-up on the same screen.
    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        question = ""
        transcript.append(ChatMessage(role: .user, text: q))
        let ctx = watcher.current ?? watcher.sample()

        Task {
            var content: [[String: Any]] = []
            if config.attachScreenshotOnText, needsFreshCapture(for: ctx) {
                status = "Capturing screen…"
                do {
                    let raw = try await ScreenCapture.captureDisplay()
                    if let shot = ScreenCapture.encode(ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)) {
                        content.append(imageBlock(shot))
                        lastCapture = (Date(), ctx)
                        Log.info("ask: screenshot \(shot.width)x\(shot.height) \(shot.sizeKB)KB")
                    }
                } catch {
                    Log.info("ask: no screenshot: \(error.localizedDescription)")
                }
            }
            let text = Prompt.context(ctx, recent: watcher.history) + packsSection(ctx) + "\n## Question\n\(q)\n"
            content.append(["type": "text", "text": text])
            await send(content: content, ctx: ctx)
        }
    }

    /// Wand pick: full screenshot with a ring at the click, plus a zoomed crop, then a short identify-and-offer reply.
    func wandPick(_ target: WandTarget) {
        guard !busy else { return }
        expanded = true
        transcript.append(ChatMessage(role: .wand, text: target.shortLabel))
        let ctx = watcher.sample() ?? watcher.current

        Task {
            status = "Capturing screen…"
            var content: [[String: Any]] = []
            do {
                let raw = try await ScreenCapture.captureDisplay(containing: target.screenPoint)
                let p = raw.imagePoint(target.screenPoint)
                let full = ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)
                let f = CGFloat(full.width) / CGFloat(raw.image.width)
                let annotated = ScreenCapture.annotate(full, ringAt: CGPoint(x: p.x * f, y: p.y * f))
                if let shot = ScreenCapture.encode(annotated) { content.append(imageBlock(shot)) }
                let cropSize = CGSize(width: 900 * raw.pixelsPerPoint / 2, height: 560 * raw.pixelsPerPoint / 2)
                if let cropped = ScreenCapture.crop(raw.image, around: p, size: cropSize), let shot = ScreenCapture.encode(cropped) {
                    content.append(imageBlock(shot))
                }
                lastCapture = (Date(), ctx)
                Log.info("wand: images \(content.count), point \(Int(p.x)),\(Int(p.y))")
            } catch {
                transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
                Log.info("wand: capture failed: \(error.localizedDescription)")
            }
            let text = Prompt.context(ctx, recent: watcher.history) + packsSection(ctx) + "\n" + Prompt.wandInstruction(target: target, ctx: ctx)
            content.append(["type": "text", "text": text])
            await send(content: content, ctx: ctx)
        }
    }

    // MARK: internals

    private func needsFreshCapture(for ctx: ScreenContext?) -> Bool {
        guard config.screenshotReuseSeconds > 0, let last = lastCapture else { return true }
        if Date().timeIntervalSince(last.at) > config.screenshotReuseSeconds { return true }
        if let a = last.scene, let b = ctx { return !a.sameScene(as: b) }
        return true
    }

    private func imageBlock(_ shot: Screenshot) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]]
    }

    private func packsSection(_ ctx: ScreenContext?) -> String {
        let sel = registry.select(for: ctx)
        var s = Prompt.toolPacks(active: sel.active, global: sel.global, others: sel.others, stuffLimit: config.docsStuffLimitChars)
        let missing = registry.missingRequirements(for: sel.active + sel.global)
        if !missing.isEmpty {
            s += "\n## Not configured yet\n"
            for m in missing { s += "- \(m.pack.name) needs \(m.keys.joined(separator: ", ")). Its scripts will fail until the user adds it in Familiar Settings (right-click the bubble → Settings…).\n" }
        }
        return s
    }

    /// Re-create the API client after settings change.
    func reconfigure(_ newConfig: Config) {
        config = newConfig
        client = newConfig.resolvedApiKey.map { ClaudeClient(config: newConfig, apiKey: $0) }
        objectWillChange.send()
    }

    /// Set by the app; nil in headless runs without control.
    var control: ComputerController?

    private func toolDefinitions(_ ctx: ScreenContext?) -> [[String: Any]] {
        let sel = registry.select(for: ctx)
        let scripts = (sel.active + sel.global).flatMap(\.scripts).map(\.definition)
        var tools = scripts + BuiltinTools.definitions
        if config.allowControl, control != nil {
            tools.append(ComputerController.findDefinition)
            tools.append(ComputerController.toolsetDefinition)
        }
        return tools
    }

    private func send(content: [[String: Any]], ctx: ScreenContext?) async {
        guard let client else {
            transcript.append(ChatMessage(role: .error, text: "No API key. Put it in \(Config.file.path) under \"apiKey\" (or export ANTHROPIC_API_KEY) and relaunch."))
            return
        }
        busy = true
        suggestions = []
        status = "Thinking…"
        stripOldImages()
        // Instructions first, then images (what the computer-use guidance recommends); cache breakpoint on the last block
        // so images stay cached across tool rounds.
        var newContent = content.filter { $0["type"] as? String == "text" } + content.filter { $0["type"] as? String != "text" }
        if var last = newContent.last {
            last["cache_control"] = ["type": "ephemeral"]
            newContent[newContent.count - 1] = last
        }
        apiMessages.append(["role": "user", "content": newContent])
        trimHistory()

        let tools = toolDefinitions(ctx)
        let registry = self.registry
        let control = self.control
        let controlAllowed = config.allowControl && control != nil
        control?.reset()
        client.maxToolRounds = controlAllowed ? 40 : 8
        client.shouldStop = { [weak control] in control?.stopped ?? false }
        let executor: ToolExecutor = { name, input, toolset in
            if toolset == "computer" {
                guard controlAllowed, let control else { return .text("Computer control is off. The user can enable it in Familiar Settings.", isError: true) }
                return await control.perform(name, input)
            }
            if name == "find_on_screen" {
                guard controlAllowed, let control else { return .text("Computer control is off.", isError: true) }
                return control.find(input["query"] as? String ?? "")
            }
            if BuiltinTools.names.contains(name) {
                return BuiltinTools.execute(name, input, root: registry.root)
            }
            guard let script = registry.script(named: name) else { return .text("Unknown tool \(name)", isError: true) }
            let pack = registry.packs.first { $0.dirName == script.packDir }
            do { return .text(try await registry.runner.run(script, args: input, context: ctx, secrets: pack?.requires ?? [])) }
            catch { return .text(error.localizedDescription, isError: true) }
        }

        let started = Date()
        defer { control?.end() }
        do {
            var messages = apiMessages
            let system = Prompt.system + (controlAllowed ? Prompt.control : "")
            let reply = try await client.converse(system: system, tools: tools, messages: &messages,
                                                  executor: executor, onStatus: { [weak self] s in Task { @MainActor in self?.status = s } })
            apiMessages = messages
            let (text, sugg) = Self.splitSuggestions(reply.text)
            transcript.append(ChatMessage(role: .assistant, text: text))
            suggestions = sugg
            let secs = String(format: "%.1f", Date().timeIntervalSince(started))
            status = "\(reply.inputTokens) in · \(reply.outputTokens) out · \(reply.toolCalls) tool call\(reply.toolCalls == 1 ? "" : "s") · \(secs)s"
            Log.info("reply: \(reply.outputTokens) out, \(reply.inputTokens) in (cache read \(reply.cacheRead)), \(reply.toolCalls) tool calls, \(secs)s")
        } catch {
            apiMessages.removeLast()   // drop the failed user turn so the history stays consistent
            transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
            status = ""
            Log.info("error: \(error.localizedDescription)")
        }
        busy = false
    }

    /// Replace images in earlier user turns with a placeholder, and drop stale cache breakpoints.
    private func stripOldImages() {
        for i in apiMessages.indices where apiMessages[i]["role"] as? String == "user" {
            guard let content = apiMessages[i]["content"] as? [[String: Any]] else { continue }
            apiMessages[i]["content"] = content.map { block -> [String: Any] in
                if block["type"] as? String == "image" { return ["type": "text", "text": "[earlier screenshot omitted]"] }
                var b = block; b["cache_control"] = nil; return b
            }
        }
    }

    /// Keep the tail of the conversation, never cutting between a tool_use and its tool_result.
    private func trimHistory(maxMessages: Int = 24) {
        while apiMessages.count > maxMessages {
            apiMessages.removeFirst()
            while let first = apiMessages.first {
                let isPlainUser = first["role"] as? String == "user" &&
                    !((first["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false)
                if isPlainUser { break }
                apiMessages.removeFirst()
            }
        }
    }

    static func splitSuggestions(_ text: String) -> (String, [String]) {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces),
              let range = last.range(of: #"^\**Suggestions\**:\s*"#, options: [.regularExpression, .caseInsensitive]) else { return (text, []) }
        let items = last[range.upperBound...].split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*_")) }
            .filter { !$0.isEmpty }
        lines.removeLast()
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), Array(items.prefix(3)))
    }
}
