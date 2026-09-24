import AppKit
import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case user, wand, assistant, error, draft }   // draft: a note Familiar starts itself (a watched workflow's title)
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
    @Published var cardSize = NSSize(width: 400, height: 540)
    @Published var watching = false
    @Published var pendingDraft: PackDraft?

    var config: Config
    let watcher: ContextWatcher
    let registry: ToolRegistry
    var onStartWand: (() -> Void)?
    var onHideBubble: (() -> Void)?
    enum DragPhase { case moved, ended }
    var onDragBubble: ((DragPhase) -> Void)?   // the app moves the panel using the global mouse position
    var onOpenSettings: (() -> Void)?
    var onPoke: (() -> Void)?             // single click on the note: reaction only, plus a first-time hint
    var onResizeCard: ((NSSize, Bool) -> Void)?   // new size, and whether the drag ended (persist)
    var onToggleLarge: (() -> Void)?

    private var client: ClaudeClient?
    private var apiMessages: [[String: Any]] = []
    private var lastCapture: (at: Date, scene: ScreenContext?)?
    private(set) lazy var recorder = WatchRecorder(config: config, watcher: watcher)
    private var pendingRecording: Recording?     // stopped, waiting for a purpose, being written up, or under review
    private var awaitingPurpose = false
    private var draftFailed = false

    static let continueTab = "Continue without a description"
    static let keepTab = "Keep it"
    static let discardTab = "Discard"
    static let retryTab = "Try again"

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
        pendingDraft = nil          // the recording folder stays on disk
        pendingRecording = nil
        awaitingPurpose = false
        draftFailed = false
    }

    func startWand() {
        guard !busy else { return }
        guard !watching else { status = "Watching — stop watching before picking up the pen."; return }
        onStartWand?()
    }

    func askSuggestion(_ s: String) {
        if let rec = pendingRecording {
            if awaitingPurpose, s == Self.continueTab { awaitingPurpose = false; summarize(rec, purpose: nil); return }
            if pendingDraft != nil || draftFailed {
                if s == Self.keepTab { Task { await keep() }; return }
                if s == Self.discardTab { discard(); return }
                if s == Self.retryTab { summarize(rec, purpose: rec.meta.purpose); return }
            }
        }
        question = s
        ask()
    }

    // MARK: watch me

    func toggleWatching() { if watching { stopWatching() } else { startWatching() } }

    /// Starts recording: the pad closes, the pen and control are off until the recording stops.
    func startWatching() {
        guard !busy, !watching else { return }
        guard Permissions.screenRecordingGranted else {
            expanded = true
            transcript.append(ChatMessage(role: .error, text: ScreenCaptureError.notPermitted.localizedDescription))
            return
        }
        recorder.config = config
        recorder.hotkeyLabel = HotKey.display(config.hotkey.isEmpty ? "control+option+space" : config.hotkey)
        do { try recorder.start() } catch {
            expanded = true
            transcript.append(ChatMessage(role: .error, text: "Could not start recording: \(error.localizedDescription)"))
            return
        }
        pendingDraft = nil; pendingRecording = nil; awaitingPurpose = false; draftFailed = false
        watching = true
        expanded = false
        status = ""
        contextLine = "Watching…"
    }

    /// Stops the recorder and asks, on the pad, what the user was doing.
    func stopWatching() {
        guard watching else { return }
        let rec = recorder.stop(purpose: nil)
        watching = false
        contextLine = watcher.current?.summaryLine ?? (watcher.isRunning ? "Watching…" : "Watcher off")
        expanded = true
        let seen = rec.events.filter { $0.kind != "scene" }
        guard !seen.isEmpty else {
            try? FileManager.default.removeItem(at: rec.dir)
            transcript.append(ChatMessage(role: .assistant, text: "I didn't see you do anything, so there is nothing to write up."))
            suggestions = []
            return
        }
        pendingRecording = rec
        awaitingPurpose = true
        transcript.append(ChatMessage(role: .assistant, text: "Got it — \(rec.meta.clicks) click\(rec.meta.clicks == 1 ? "" : "s"). What were you doing? Write one line below, or press Continue."))
        suggestions = [Self.continueTab]
    }

    /// Asks Claude to write the recording up, then puts the draft on the pad for review.
    func summarize(_ rec: Recording, purpose: String?) {
        guard !busy else { return }
        var rec = rec
        if let purpose, !purpose.isEmpty { rec.meta.purpose = purpose; try? rec.saveMeta() }
        pendingRecording = rec
        pendingDraft = nil
        draftFailed = false
        busy = true
        suggestions = []
        status = "Writing it up…"
        guard let client else {
            transcript.append(ChatMessage(role: .error, text: "No API key. Add it in Familiar Settings, then press Try again."))
            draftFailed = true; busy = false; status = ""
            suggestions = [Self.retryTab, Self.discardTab]
            return
        }
        let config = self.config
        let key = client.apiKey
        Task {
            let started = Date()
            do {
                let draft = try await WatchSummarizer.summarize(rec, purpose: purpose, config: config, apiKey: key,
                                                                onStatus: { [weak self] s in Task { @MainActor in self?.status = s == "Thinking…" ? "Writing it up…" : s } })
                pendingDraft = draft
                transcript.append(ChatMessage(role: .draft, text: draft.parsed ? draft.workflowTitle : "Could not write this up"))
                transcript.append(ChatMessage(role: .assistant, text: Self.draftBody(draft, root: registry.root)))
                suggestions = draft.parsed ? [Self.keepTab, Self.discardTab] : [Self.discardTab]
                if !draft.parsed { draftFailed = true; suggestions = [Self.retryTab, Self.discardTab] }
                status = String(format: "draft in %.0fs · confidence %.0f%%", Date().timeIntervalSince(started), draft.confidence * 100)
            } catch {
                transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
                draftFailed = true
                suggestions = [Self.retryTab, Self.discardTab]
                status = ""
            }
            busy = false
        }
    }

    /// Writes the pack files and reloads the tools.
    func keep() async {
        guard let draft = pendingDraft, draft.parsed, !busy else { return }
        busy = true
        status = "Saving…"
        do {
            let files = try PackWriter.write(draft, root: registry.root)
            await registry.reload()
            let rel = files.map { $0.path.replacingOccurrences(of: registry.root.path + "/", with: "") }
            transcript.append(ChatMessage(role: .assistant, text: "Saved into \(registry.root.path)/\(draft.packDir)/:\n" + rel.map { "- \($0)" }.joined(separator: "\n") + "\nIt will be used whenever you are on \(draft.matchURLs.first ?? draft.packName)."))
            pendingDraft = nil
            pendingRecording = nil
            suggestions = []
            status = ""
        } catch {
            transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
            suggestions = [Self.keepTab, Self.discardTab]
        }
        busy = false
    }

    /// Deletes the recording folder and forgets the draft.
    func discard() {
        if let rec = pendingRecording { try? FileManager.default.removeItem(at: rec.dir) }
        pendingDraft = nil
        pendingRecording = nil
        awaitingPurpose = false
        draftFailed = false
        suggestions = []
        status = ""
        transcript.append(ChatMessage(role: .assistant, text: "Discarded. The recording was deleted and nothing was saved."))
    }

    /// The draft as it reads on a note: the steps, a short Screens section, the caveats, and where Keep would put it.
    static func draftBody(_ d: PackDraft, root: URL) -> String {
        guard d.parsed else {
            return "I couldn't turn this into a pack entry. Here is what came back:\n\n" + d.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var s = flatten(d.workflowMarkdown)
        let screens = flatten(d.screensMarkdown)
        if !screens.isEmpty { s += "\n\n**Screens**\n" + (screens.count > 1400 ? String(screens.prefix(1400)) + "…" : screens) }
        if !d.caveats.isEmpty { s += "\n\n" + d.caveats.map { "_\($0)_" }.joined(separator: "\n") }
        s += "\n\nKeep it → \(root.lastPathComponent)/\(d.packDir)/docs/workflows/\(d.workflowSlug).md"
        return s
    }

    /// The pad renders inline Markdown line by line, so headings become bold lines.
    private static func flatten(_ md: String) -> String {
        md.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return line }
            return "**" + t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**"
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Typed question. Always attaches a fresh screenshot as context (the chat card itself is excluded from the capture),
    /// unless `screenshotReuseSeconds` allows reusing the last one for a quick follow-up on the same screen.
    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        question = ""
        transcript.append(ChatMessage(role: .user, text: q))
        if awaitingPurpose, let rec = pendingRecording {   // the line after "what were you doing?" is the purpose
            awaitingPurpose = false
            summarize(rec, purpose: q)
            return
        }
        let ctx = watcher.current ?? watcher.sample()

        Task {
            var content: [[String: Any]] = []
            let attach: Bool
            switch config.screenshotMode {
            case "always": attach = true
            case "never": attach = false
            default: attach = Self.soundsScreenRelated(q)
            }
            Log.info("ask: screenshot \(attach ? "attached" : "skipped") (mode \(config.screenshotMode))")
            if attach, needsFreshCapture(for: ctx) {
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

    /// Cheap intent guess for typed questions: deictic words and UI nouns mean "about the screen".
    static func soundsScreenRelated(_ q: String) -> Bool {
        let t = " " + q.lowercased().replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression) + " "
        if t.split(separator: " ").count <= 3 { return true }   // "why?", "and this?", "what now" refer to the screen
        let cues = [" this ", " that ", " these ", " those ", " here ", " it ", " its ", " screen", " page", " button", " field",
                    " form", " tab ", " menu", " dialog", " popup", " error", " message", " window", " greyed", " grayed",
                    " disabled", " highlighted", " selected", " why is", " why can't", " why cant", " why does", " what does",
                    " what is this", " what's this", " where is", " where's", " which one", " on my screen", " in front of me",
                    " cell", " column", " row ", " sheet", " formula", " dropdown", " checkbox", " link", " icon"]
        return cues.contains { t.contains($0) }
    }

    /// Fresh screenshot for the look_at_screen tool.
    private func lookAtScreen(_ ctx: ScreenContext?) async -> ToolResult {
        do {
            let raw = try await ScreenCapture.captureDisplay()
            guard let shot = ScreenCapture.encode(ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)) else {
                return .text("Could not encode the screenshot.", isError: true)
            }
            lastCapture = (Date(), ctx)
            Log.info("look_at_screen: \(shot.width)x\(shot.height) \(shot.sizeKB)KB")
            return .blocks([imageBlock(shot)])
        } catch { return .text(error.localizedDescription, isError: true) }
    }

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
        recorder.config = newConfig
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
        let controlAllowed = config.allowControl && control != nil && !watching
        control?.reset()
        client.maxToolRounds = controlAllowed ? 40 : 8
        client.shouldStop = { [weak control] in control?.stopped ?? false }
        let executor: ToolExecutor = { [weak self] name, input, toolset in
            if toolset == "computer" {
                guard controlAllowed, let control else { return .text("Computer control is off. The user can enable it in Familiar Settings.", isError: true) }
                return await control.perform(name, input)
            }
            if name == "find_on_screen" {
                guard controlAllowed, let control else { return .text("Computer control is off.", isError: true) }
                return control.find(input["query"] as? String ?? "")
            }
            if name == "look_at_screen" {
                guard let self else { return .text("unavailable", isError: true) }
                return await self.lookAtScreen(ctx)
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
