import AppKit
import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case user, wand, assistant, error, draft, learned, note }   // draft/learned: a note Familiar starts itself (a watched workflow's title), before and after Keep; note: a sticky note someone left on the control
    let id = UUID()
    let role: Role
    let text: String
    var meta: String? = nil        // note: who left it and when
    var warning = false            // note: a warning rather than a tip
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
    var onCancelWand: (() -> Void)?       // the app drops an active pen before a recording starts
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
    private var stopping = false                 // recorder.stop is draining its last capture
    private var deferredPurposePrompt: Recording?   // stopped while a question was in flight: ask once the reply lands
    private var purposeMessageID: UUID?          // the typed purpose line, folded into the draft note when it arrives

    static let continueTab = "Skip the description"
    static let keepTab = "Keep it"
    static let discardTab = "Discard"
    static let retryTab = "Try again"
    static let reservedTabs = [continueTab, keepTab, discardTab, retryTab]

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
        // A cleared pad forgets the recording too: nothing was kept, so nothing stays on disk.
        if let rec = pendingRecording { try? FileManager.default.removeItem(at: rec.dir) }
        pendingDraft = nil
        pendingRecording = nil
        awaitingPurpose = false
        draftFailed = false
        purposeMessageID = nil
    }

    func startWand() {
        guard !busy else { return }
        guard !watching else { status = "Watching — stop watching before picking up the pen."; return }
        onStartWand?()
    }

    func askSuggestion(_ s: String) {
        if awaitingPurpose {
            if s == Self.continueTab, let rec = pendingRecording { awaitingPurpose = false; summarize(rec, purpose: nil); return }
            if s == Self.discardTab { discard(); return }
        }
        if pendingDraft != nil || draftFailed {
            if s == Self.keepTab { Task { await keep() }; return }
            if s == Self.discardTab { discard(); return }
            if s == Self.retryTab, let rec = pendingRecording { summarize(rec, purpose: rec.meta.purpose); return }
        }
        if Self.reservedTabs.contains(s) { suggestions = reviewTabs([]); return }   // a stale tab: never a question for Claude
        question = s
        ask()
    }

    /// The tabs a note should carry given what is pending, on top of Claude's own follow-ups.
    private func reviewTabs(_ sugg: [String]) -> [String] {
        if awaitingPurpose { return [Self.continueTab, Self.discardTab] }
        if pendingDraft != nil { return sugg + [Self.keepTab, Self.discardTab] }
        if draftFailed { return sugg + [Self.retryTab, Self.discardTab] }
        return sugg
    }

    // MARK: watch me

    func toggleWatching() { if watching { stopWatching() } else { startWatching() } }

    private func recordingLine(_ clicks: Int) -> String {
        "Recording — \(clicks) click\(clicks == 1 ? "" : "s") · \(recorder.hotkeyLabel) to stop"
    }

    /// Starts recording: the pad closes, the pen and control are off until the recording stops.
    func startWatching() {
        guard !busy, !watching, !stopping else { return }
        if pendingRecording != nil || pendingDraft != nil {
            expanded = true
            transcript.append(ChatMessage(role: .error, text: "Keep or discard the draft on the pad first."))
            suggestions = reviewTabs([])
            return
        }
        guard Permissions.screenRecordingGranted else {
            expanded = true
            transcript.append(ChatMessage(role: .error, text: ScreenCaptureError.notPermitted.localizedDescription))
            return
        }
        onCancelWand?()
        var warned = false
        if !Permissions.accessibilityGranted {
            Permissions.requestAccessibility()
            transcript.append(ChatMessage(role: .error, text: "Without Accessibility I can't see what you click or type, so this will be screenshots only. Grant it in the menu bar (Accessibility: not granted) for a useful write-up."))
            warned = true
        }
        recorder.config = config
        recorder.hotkeyLabel = HotKey.display(config.hotkey.isEmpty ? "control+option+space" : config.hotkey)
        recorder.onClickCount = { [weak self] n in guard let self else { return }; self.contextLine = self.recordingLine(n) }
        do { try recorder.start() } catch {
            expanded = true
            transcript.append(ChatMessage(role: .error, text: "Could not start recording: \(error.localizedDescription)"))
            return
        }
        pendingDraft = nil; pendingRecording = nil; awaitingPurpose = false; draftFailed = false
        suggestions = []
        watching = true
        expanded = warned            // the warning stays in view; otherwise the pad gets out of the way
        status = ""
        contextLine = recordingLine(0)
    }

    /// Stops the recorder (waiting up to 2 s for the last click's screenshot), then asks on the pad what the user was doing.
    func stopWatching() {
        guard watching, !stopping else { return }
        stopping = true
        Task {
            let rec = await recorder.stop(purpose: nil)
            stopping = false
            watching = false
            contextLine = watcher.current?.summaryLine ?? (watcher.isRunning ? "Watching…" : "Watcher off")
            if busy { deferredPurposePrompt = rec } else { promptForPurpose(rec) }
        }
    }

    /// Quit mid-recording or mid-review: nothing is kept, nothing is left behind.
    func abortWatching() {
        recorder.abandon()
        if let rec = pendingRecording { try? FileManager.default.removeItem(at: rec.dir) }
        pendingRecording = nil
        pendingDraft = nil
        watching = false
    }

    private func promptForPurpose(_ rec: Recording) {
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
        transcript.append(ChatMessage(role: .assistant, text: "Got it — \(rec.meta.clicks) click\(rec.meta.clicks == 1 ? "" : "s"). What were you doing? Write one line below, or use a tab."))
        suggestions = reviewTabs([])
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
            suggestions = reviewTabs([])
            return
        }
        let config = self.config
        let key = client.apiKey
        Task {
            let started = Date()
            var result: Result<PackDraft, Error>
            do {
                result = .success(try await WatchSummarizer.summarize(rec, purpose: purpose, config: config, apiKey: key,
                                                                      onStatus: { [weak self] s in Task { @MainActor in self?.status = s == "Thinking…" ? "Writing it up…" : s } }))
            } catch { result = .failure(error) }
            busy = false
            guard pendingRecording?.dir == rec.dir else { status = ""; return }   // the pad was cleared meanwhile: the recording is gone
            switch result {
            case .success(let draft):
                pendingDraft = draft
                if let id = purposeMessageID { transcript.removeAll { $0.id == id } }   // the line lives on inside the draft note
                purposeMessageID = nil
                transcript.append(ChatMessage(role: .draft, text: draft.parsed ? draft.workflowTitle : "Could not write this up"))
                transcript.append(ChatMessage(role: .assistant, text: Self.draftBody(draft, purpose: rec.meta.purpose, root: registry.root)))
                if !draft.parsed { draftFailed = true }
                suggestions = reviewTabs([])
                status = String(format: "draft in %.0fs · confidence %.0f%%", Date().timeIntervalSince(started), draft.confidence * 100)
            case .failure(let error):
                transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
                draftFailed = true
                suggestions = reviewTabs([])
                status = ""
            }
        }
    }

    /// Writes the pack files, reloads the tools, and deletes the recording: the pack is the product.
    func keep() async {
        guard let draft = pendingDraft, draft.parsed, !busy, let rec = pendingRecording else { return }
        busy = true
        status = "Saving…"
        do {
            let files = try PackWriter.write(draft, root: registry.root)
            await registry.reload()
            try? FileManager.default.removeItem(at: rec.dir)
            let packRoot = registry.root.appendingPathComponent(draft.packDir).path + "/"
            let rel = files.map { $0.path.replacingOccurrences(of: packRoot, with: "") }
            let whereText = draft.matchURLs.first ?? draft.matchTitles.first.map { "“\($0)”" } ?? draft.matchBundles.first ?? draft.packName
            if let i = transcript.lastIndex(where: { $0.role == .draft }) {
                transcript[i] = ChatMessage(role: .learned, text: transcript[i].text)
            }
            transcript.append(ChatMessage(role: .assistant, text: "Kept as \(draft.packName). I'll use it whenever you're on \(whereText). The recording itself is deleted.\n" + rel.map { "- \($0)" }.joined(separator: "\n")))
            pendingDraft = nil
            pendingRecording = nil
            draftFailed = false
            suggestions = []
            status = ""
        } catch {
            transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
            suggestions = reviewTabs([])
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
        purposeMessageID = nil
        suggestions = []
        status = ""
        transcript.append(ChatMessage(role: .assistant, text: "Discarded. The recording was deleted and nothing was saved."))
    }

    /// The draft as it reads on a note: what the user said, the steps, a short Screens section, the caveats, where
    /// the pack would apply, and where Keep would put it.
    static func draftBody(_ d: PackDraft, purpose: String? = nil, root: URL) -> String {
        var s = ""
        if let purpose, !purpose.isEmpty { s += "_You said: “\(purpose)”_\n\n" }
        guard d.parsed else {
            return s + "I couldn't turn this into a pack entry. Here is what came back:\n\n" + d.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s += flatten(d.workflowMarkdown)
        let screens = flatten(d.screensMarkdown)
        if !screens.isEmpty { s += "\n\n**Screens**\n" + (screens.count > 1400 ? String(screens.prefix(1400)) + "…" : screens) }
        if !d.caveats.isEmpty { s += "\n\n" + d.caveats.map { "_\($0)_" }.joined(separator: "\n") }
        let matches = d.matchURLs + d.matchTitles.map { "“\($0)”" } + d.matchBundles
        s += "\n\nMatches: " + (matches.isEmpty ? "nothing (would not be saved)" : matches.joined(separator: ", "))
        s += "\nKeep it → \(root.lastPathComponent)/\(d.packDir)/docs/workflows/\(d.workflowSlug).md"
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
        let m = ChatMessage(role: .user, text: q)
        transcript.append(m)
        if awaitingPurpose, let rec = pendingRecording {   // the line after "what were you doing?" is the purpose
            awaitingPurpose = false
            purposeMessageID = m.id
            summarize(rec, purpose: q)
            return
        }
        if pendingDraft != nil || draftFailed {
            transcript.append(ChatMessage(role: .error, text: "Keep or discard the draft above first."))
            suggestions = reviewTabs([])
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

    /// Wand pick: full screenshot with a ring at the click (or the ink stroke, for a circled region), plus a zoomed crop,
    /// then a short identify-and-offer reply. Notes stuck on the target go on the pad first, and into the prompt.
    func wandPick(_ target: WandTarget) {
        guard !busy else { return }
        expanded = true
        transcript.append(ChatMessage(role: .wand, text: target.shortLabel))
        for n in target.notes { transcript.append(ChatMessage(role: .note, text: n.text, meta: n.byline, warning: n.isWarning)) }
        let ctx = watcher.sample() ?? watcher.current

        Task {
            status = "Capturing screen…"
            var content: [[String: Any]] = []
            do {
                let raw = try await ScreenCapture.captureDisplay(containing: target.screenPoint)
                let full = ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)
                let f = CGFloat(full.width) / CGFloat(raw.image.width)
                if let stroke = target.stroke, let region = target.region {
                    let pts = stroke.map { raw.imagePoint($0) }
                    let annotated = ScreenCapture.annotate(full, stroke: pts.map { CGPoint(x: $0.x * f, y: $0.y * f) })
                    if let shot = ScreenCapture.encode(annotated) { content.append(imageBlock(shot)) }
                    let tl = raw.imagePoint(NSPoint(x: region.minX, y: region.maxY))
                    let rect = CGRect(x: tl.x, y: tl.y, width: region.width * raw.pixelsPerPoint, height: region.height * raw.pixelsPerPoint)
                    let pad = max(40 * raw.pixelsPerPoint, CGFloat(min(raw.image.width, raw.image.height)) * 0.04)
                    if let cropped = ScreenCapture.crop(raw.image, around: rect, padding: pad, maxLongEdge: 1568), let shot = ScreenCapture.encode(cropped) {
                        content.append(imageBlock(shot))
                    }
                    Log.info("wand: images \(content.count), region \(Int(rect.width))x\(Int(rect.height))px")
                } else {
                    let p = raw.imagePoint(target.screenPoint)
                    let annotated = ScreenCapture.annotate(full, ringAt: CGPoint(x: p.x * f, y: p.y * f))
                    if let shot = ScreenCapture.encode(annotated) { content.append(imageBlock(shot)) }
                    let cropSize = CGSize(width: 900 * raw.pixelsPerPoint / 2, height: 560 * raw.pixelsPerPoint / 2)
                    if let cropped = ScreenCapture.crop(raw.image, around: p, size: cropSize), let shot = ScreenCapture.encode(cropped) {
                        content.append(imageBlock(shot))
                    }
                    Log.info("wand: images \(content.count), point \(Int(p.x)),\(Int(p.y))")
                }
                lastCapture = (Date(), ctx)
            } catch {
                transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
                Log.info("wand: capture failed: \(error.localizedDescription)")
            }
            let elsewhere = registry.notes(for: ctx).filter { n in !target.notes.contains(n) }
            let text = Prompt.context(ctx, recent: watcher.history) + packsSection(ctx, notes: false) + "\n"
                + Prompt.wandInstruction(target: target, ctx: ctx) + Prompt.notes(onTarget: target.notes, elsewhere: elsewhere)
            content.append(["type": "text", "text": text])
            await send(content: content, ctx: ctx)
        }
    }

    // MARK: notes

    /// A note written with the pen: into the first active pack for the scene, or a pack made for it.
    func saveNote(_ note: StickyNote) {
        let ctx = watcher.current ?? watcher.sample()
        Task {
            do {
                let pack: ToolPack
                if let p = registry.pack(holding: note.id) { pack = p }
                else { pack = try await registry.packForNote(anchor: note.anchor, ctx: ctx, appName: ctx?.appName) }
                try registry.put(note, in: pack)
                status = "Note kept in \(pack.dirName)/\(NoteStore.fileName)"
                Log.info("notes: kept \(note.kind) on \(note.anchor.summary) in \(pack.dirName)")
            } catch {
                expanded = true
                transcript.append(ChatMessage(role: .error, text: "Could not keep the note: \(error.localizedDescription)"))
            }
        }
    }

    func deleteNote(_ id: String) {
        do { try registry.removeNote(id: id); status = "Note removed" }
        catch { transcript.append(ChatMessage(role: .error, text: "Could not remove the note: \(error.localizedDescription)")) }
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

    private func packsSection(_ ctx: ScreenContext?, notes: Bool = true) -> String {
        let sel = registry.select(for: ctx)
        var s = Prompt.toolPacks(active: sel.active, global: sel.global, others: sel.others, stuffLimit: config.docsStuffLimitChars)
        if notes { s += Prompt.notes(onTarget: [], elsewhere: registry.notes(for: ctx)) }
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
            suggestions = reviewTabs(sugg)
            let secs = String(format: "%.1f", Date().timeIntervalSince(started))
            status = "\(reply.inputTokens) in · \(reply.outputTokens) out · \(reply.toolCalls) tool call\(reply.toolCalls == 1 ? "" : "s") · \(secs)s"
            Log.info("reply: \(reply.outputTokens) out, \(reply.inputTokens) in (cache read \(reply.cacheRead)), \(reply.toolCalls) tool calls, \(secs)s")
        } catch {
            apiMessages.removeLast()   // drop the failed user turn so the history stays consistent
            transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
            suggestions = reviewTabs([])
            status = ""
            Log.info("error: \(error.localizedDescription)")
        }
        busy = false
        if let rec = deferredPurposePrompt { deferredPurposePrompt = nil; promptForPurpose(rec) }
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
