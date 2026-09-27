import FamiliarContracts
import FamiliarRuntime
import Combine
import AppKit
import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case user, wand, assistant, error, draft, learned, note, receipt }   // draft/learned: a note Familiar starts itself (a watched workflow's title), before and after Keep; note: a sticky note someone left on the control; receipt: the last frame of a background job
    let id = UUID()
    let role: Role
    let text: String
    var meta: String? = nil        // note: who left it and when
    var warning = false            // note: a warning rather than a tip
    var image: CGImage? = nil      // receipt: the target window when the job ended
}

@MainActor
final class Assistant: ObservableObject {
    @Published var question = ""
    @Published var transcript: [ChatMessage] = []
    @Published var chatBusy = false { didSet { learning.setPurposeDeliveryPaused(chatBusy) } }
    var busy: Bool { chatBusy || learning.busy }
    @Published var status = ""
    @Published var contextLine = "Watching…"
    @Published var suggestions: [String] = []
    var watching: Bool { learning.watching }
    var pendingDraft: PackDraft? { learning.pendingDraft }
    @Published var backgroundControl = true   // mirror of config.controlInBackground for the pad's hand button

    var config: Config
    let watcher: ContextWatcher
    let registry: ToolRegistry
    var onStartWand: (() -> Void)?
    var onCancelWand: (() -> Void)?       // the app drops an active pen before a recording starts
    var onSetControlLane: ((_ allow: Bool, _ background: Bool) -> Void)?   // the app persists both and reconfigures

    let learning: WatchLearnSession
    let notes: ContextNotesService
    private var subscriptions = Set<AnyCancellable>()
    let shell: ShellState
    let execution: ExecutionCoordinator
    let desktop: DesktopExecutionService?
    private let idlePeek = PeekFeed()
    var peek: PeekFeed { desktop?.peek ?? idlePeek }

    /// The pad's hand: on = work in the window you asked from. Clicking it while control is off turns control on
    /// (the user is flipping the gate themselves), in the background lane, which never takes the mouse unasked.
    var backgroundOn: Bool { config.allowControl && backgroundControl }
    func toggleBackgroundControl() {
        if !config.allowControl {
            onSetControlLane?(true, true)
            status = "Control is on — I'll work in the window while you carry on, and ask before I ever take the mouse."
        } else {
            onSetControlLane?(true, !backgroundControl)
            status = backgroundControl ? "I'll take the mouse when you ask me to do things." : "I'll work in the window while you carry on."
        }
    }

    private var client: (any ConversationClient)?
    private var captureGeneration = 0   // invalidates a screen capture prepared before Clear/provider change
    private var lastCapture: (at: Date, scene: ScreenContext?)?
    private var awaitingPurpose: Bool { learning.awaitingPurpose }
    private var draftFailed: Bool { learning.draftFailed }
    private var purposeMessageID: UUID?          // the typed purpose line, folded into the draft note when it arrives

    static let continueTab = "Skip the description"
    static let keepTab = "Keep it"
    static let discardTab = "Discard"
    static let retryTab = "Try again"
    static let reservedTabs = [continueTab, keepTab, discardTab, retryTab]

    init(config: Config, watcher: ContextWatcher, registry: ToolRegistry, shell: ShellState, learning: WatchLearnSession,
         execution: ExecutionCoordinator? = nil, desktop: DesktopExecutionService? = nil) {
        self.learning = learning
        self.notes = ContextNotesService(registry: registry)
        self.shell = shell
        self.execution = execution ?? ExecutionCoordinator()
        self.desktop = desktop
        self.config = config
        self.watcher = watcher
        self.registry = registry
        backgroundControl = config.controlInBackground
        client = ConversationBackend.make(config: config)
        learning.onEvent = { [weak self] in self?.presentLearning($0) }
        learning.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        learning.$phase.scan((wasWatching: false, watching: false)) { previous, phase in
            (wasWatching: previous.watching, watching: phase == .recording || phase == .stopping)
        }.sink { [weak self] change in
            guard let self, change.wasWatching, !change.watching else { return }
            self.contextLine = self.watcher.current?.summaryLine ?? (self.watcher.isRunning ? "Watching…" : "Watcher off")
        }.store(in: &subscriptions)
        learning.$phase.sink { [weak self] phase in
            if phase == .summarizing { self?.suggestions = [] }
        }.store(in: &subscriptions)
        learning.$status.dropFirst().sink { [weak self] in self?.status = $0 }.store(in: &subscriptions)
        learning.$clickCount.dropFirst().sink { [weak self] count in
            guard let self, self.watching else { return }
            self.contextLine = self.recordingLine(count)
        }.store(in: &subscriptions)
    }

    var hasConnection: Bool { client != nil }

    func clearConversation() {
        captureGeneration += 1
        transcript.removeAll()
        execution.conversation.clear()
        suggestions.removeAll()
        status = ""
        lastCapture = nil
        learning.clear()
        purposeMessageID = nil
    }

    func startWand() {
        guard !busy else { return }
        guard !watching else { status = "Watching — stop watching before picking up the pen."; return }
        onStartWand?()
    }

    func askSuggestion(_ s: String) {
        if awaitingPurpose {
            if s == Self.continueTab { learning.summarize(purpose: nil); return }
            if s == Self.discardTab { learning.discard(); return }
        }
        if pendingDraft != nil || draftFailed {
            if s == Self.keepTab { Task { await learning.keep() }; return }
            if s == Self.discardTab { learning.discard(); return }
            if s == Self.retryTab { learning.retry(); return }
        }
        if Self.reservedTabs.contains(s) { suggestions = reviewTabs([]); return }   // a stale tab: never a question for Claude
        if s.hasPrefix("Confirm: ") { control?.confirm(label: String(s.dropFirst("Confirm: ".count))) }   // one irreversible press may go through
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

    // MARK: Watch presentation adapter

    func toggleWatching() { if watching { stopWatching() } else { startWatching() } }

    private func recordingLine(_ clicks: Int) -> String {
        let hotkey = HotKey.display(config.hotkey.isEmpty ? "control+option+space" : config.hotkey)
        return "Recording — \(clicks) click\(clicks == 1 ? "" : "s") · \(hotkey) to stop"
    }

    /// Permissions and presentation belong to the app; recording/draft lifetime belongs to learning.
    func startWatching() {
        guard !busy, !watching, !learning.stopping else { return }
        if learning.hasPendingReview {
            shell.expanded = true
            transcript.append(ChatMessage(role: .error, text: "Keep or discard the draft on the pad first."))
            suggestions = reviewTabs([])
            return
        }
        guard Permissions.screenRecordingGranted else {
            shell.expanded = true
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
        do {
            guard try learning.start() else { return }
            shell.expanded = warned
        } catch {
            shell.expanded = true
            transcript.append(ChatMessage(role: .error, text: "Could not start recording: \(error.localizedDescription)"))
        }
    }

    func stopWatching() { learning.stop() }
    func abortWatching() { learning.abort() }

    private func presentLearning(_ event: WatchLearnSession.Event) {
        switch event {
        case .started:
            suggestions = []
            status = ""
            contextLine = recordingLine(0)
        case .stopped:
            contextLine = watcher.current?.summaryLine ?? (watcher.isRunning ? "Watching…" : "Watcher off")
        case .purposeRequested(let recording):
            shell.expanded = true
            transcript.append(ChatMessage(role: .assistant, text: "Got it — \(recording.meta.clicks) click\(recording.meta.clicks == 1 ? "" : "s"). What were you doing? Write one line below, or use a tab."))
            suggestions = reviewTabs([])
        case .emptyRecording:
            shell.expanded = true
            transcript.append(ChatMessage(role: .assistant, text: "I didn't see you do anything, so there is nothing to write up."))
            suggestions = []
        case .draftReady(let draft, let recording, _):
            if let id = purposeMessageID { transcript.removeAll { $0.id == id } }
            purposeMessageID = nil
            transcript.append(ChatMessage(role: .draft, text: draft.parsed ? draft.workflowTitle : "Could not write this up"))
            transcript.append(ChatMessage(role: .assistant, text: Self.draftBody(draft, purpose: recording.meta.purpose, root: registry.root)))
            suggestions = reviewTabs([])
        case .kept(let draft, let files):
            let packRoot = registry.root.appendingPathComponent(draft.packDir).path + "/"
            let rel = files.map { $0.path.replacingOccurrences(of: packRoot, with: "") }
            let whereText = draft.matchURLs.first ?? draft.matchTitles.first.map { "“\($0)”" } ?? draft.matchBundles.first ?? draft.packName
            if let i = transcript.lastIndex(where: { $0.role == .draft }) {
                transcript[i] = ChatMessage(role: .learned, text: transcript[i].text)
            }
            transcript.append(ChatMessage(role: .assistant, text: "Kept as \(draft.packName). I'll use it whenever you're on \(whereText). The recording itself is deleted.\n" + rel.map { "- \($0)" }.joined(separator: "\n")))
            suggestions = []
            status = ""
        case .failed(_, let error):
            transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
            suggestions = reviewTabs([])
        case .discarded:
            purposeMessageID = nil
            suggestions = []
            status = ""
            transcript.append(ChatMessage(role: .assistant, text: "Discarded. The recording was deleted and nothing was saved."))
        }
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
        if awaitingPurpose {   // the line after "what were you doing?" is the purpose
            purposeMessageID = m.id
            suggestions = []
            learning.summarize(purpose: q)
            return
        }
        if pendingDraft != nil || draftFailed {
            transcript.append(ChatMessage(role: .error, text: "Keep or discard the draft above first."))
            suggestions = reviewTabs([])
            return
        }
        let ctx = watcher.current ?? watcher.sample()
        chatBusy = true
        let generation = captureGeneration

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
                    guard generation == captureGeneration else { finishRequest(); return }
                    if let shot = ScreenCapture.encode(ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)) {
                        content.append(imageBlock(shot))
                        lastCapture = (Date(), ctx)
                        Log.info("ask: screenshot \(shot.width)x\(shot.height) \(shot.sizeKB)KB")
                    }
                } catch {
                    Log.info("ask: no screenshot: \(error.localizedDescription)")
                }
            }
            guard generation == captureGeneration else { finishRequest(); return }
            let text = Prompt.context(ctx, recent: watcher.history) + packsSection(ctx) + "\n## Question\n\(q)\n"
            content.append(["type": "text", "text": text])
            await send(content: content, ctx: ctx)
        }
    }

    /// Wand pick: full screenshot with a ring at the click (or the ink stroke, for a circled region), plus a zoomed crop,
    /// then a short identify-and-offer reply. Notes stuck on the target go on the pad first, and into the prompt.
    func wandPick(_ target: WandTarget) {
        guard !busy else { return }
        shell.expanded = true
        transcript.append(ChatMessage(role: .wand, text: target.shortLabel))
        for n in target.notes { transcript.append(ChatMessage(role: .note, text: n.text, meta: n.byline, warning: n.isWarning)) }
        let ctx = watcher.sample() ?? watcher.current
        chatBusy = true
        let generation = captureGeneration

        Task {
            status = "Capturing screen…"
            var content: [[String: Any]] = []
            do {
                let raw = try await ScreenCapture.captureDisplay(containing: target.screenPoint)
                guard generation == captureGeneration else { finishRequest(); return }
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
                guard generation == captureGeneration else { finishRequest(); return }
                transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
                Log.info("wand: capture failed: \(error.localizedDescription)")
            }
            guard generation == captureGeneration else { finishRequest(); return }
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
                let pack = try await notes.save(note, appName: ctx?.appName)
                status = "Note kept in \(pack.dirName)/\(NoteStore.fileName)"
                Log.info("notes: kept \(note.kind) on \(note.anchor.summary) in \(pack.dirName)")
            } catch {
                shell.expanded = true
                transcript.append(ChatMessage(role: .error, text: "Could not keep the note: \(error.localizedDescription)"))
            }
        }
    }

    func deleteNote(_ id: String) {
        do { try notes.remove(id); status = "Note removed" }
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
    private func lookAtScreen(_ ctx: ScreenContext?, generation: Int) async -> ToolResult {
        do {
            let raw = try await ScreenCapture.captureDisplay()
            guard let shot = ScreenCapture.encode(ScreenCapture.downscale(raw.image, maxLongEdge: config.maxImageLongEdge)) else {
                return .text("Could not encode the screenshot.", isError: true)
            }
            if generation == captureGeneration { lastCapture = (Date(), ctx) }
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
        PackContextProvider.context(for: ctx, registry: registry, docsLimit: config.docsStuffLimitChars,
                                    includeNotes: notes).promptSection
    }

    /// Re-create the API client after settings change.
    func reconfigure(_ newConfig: Config) {
        // Keep the visible conversation while dropping provider-specific tools and image state.
        if newConfig.connectionMode != config.connectionMode {
            captureGeneration += 1
            execution.conversation.retainTextForProviderChange()
            lastCapture = nil
        }
        config = newConfig
        backgroundControl = newConfig.controlInBackground
        client = ConversationBackend.make(config: newConfig)
        objectWillChange.send()
    }

    /// Set by the app; nil in headless runs without control.
    var control: ComputerController? { desktop?.control }

    private func send(content: [[String: Any]], ctx: ScreenContext?) async {
        guard let client else {
            transcript.append(ChatMessage(role: .error, text: ConversationBackend.setupMessage(config: config)))
            finishRequest()
            return
        }
        chatBusy = true
        suggestions = []
        status = "Thinking…"
        let controlAllowed = config.allowControl && desktop != nil && !watching
        let background = controlAllowed && backgroundControl
        let id = UUID()
        let generation = captureGeneration
        var receipt: DesktopExecutionService.Receipt?
        do {
            let result = try await execution.run(client: client, content: content, prepare: { [self] in
                let capture: () async -> ToolResult = { [weak self] in
                    guard let self else { return .text("unavailable", isError: true) }
                    return await self.lookAtScreen(ctx, generation: generation)
                }
                if controlAllowed, let desktop {
                    return try await desktop.prepare(id: id, registry: registry, context: ctx, background: background,
                                                     lookAtScreen: capture)
                }
                let router = try ExecutionTools.make(registry: registry, context: ctx, control: nil,
                                                     background: false, lookAtScreen: capture)
                return PreparedExecution(system: Prompt.system, router: router)
            }, stopNative: { [weak desktop] in desktop?.stop(id: id) }, cleanup: { [weak desktop] in
                receipt = desktop?.finish(id: id)
            }, onStatus: { [weak self] in self?.status = $0 })
            if result.accepted {
                switch result.outcome {
                case .reply(let reply):
                    appendReceipt(receipt, background: background, elapsed: result.elapsed)
                    let (text, tabs) = Self.splitSuggestions(reply.text)
                    transcript.append(ChatMessage(role: .assistant, text: text))
                    suggestions = reviewTabs(tabs)
                    let secs = String(format: "%.1f", result.elapsed)
                    status = "\(reply.inputTokens) in · \(reply.outputTokens) out · \(reply.toolCalls) tool call\(reply.toolCalls == 1 ? "" : "s") · \(secs)s"
                    Log.info("reply: \(reply.outputTokens) out, \(reply.inputTokens) in (cache read \(reply.cacheRead)), \(reply.toolCalls) tool calls, \(secs)s")
                case .cancelled:
                    appendReceipt(receipt, background: background, elapsed: result.elapsed)
                    transcript.append(ChatMessage(role: .assistant, text: "Stopped."))
                    suggestions = reviewTabs([])
                    status = ""
                case .failed(let error):
                    transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
                    suggestions = reviewTabs([])
                    status = ""
                    Log.info("error: \(error.localizedDescription)")
                }
            } else { status = "" }
        } catch {
            transcript.append(ChatMessage(role: .error, text: error.localizedDescription))
            status = ""
        }
        finishRequest()
    }

    private func appendReceipt(_ receipt: DesktopExecutionService.Receipt?, background: Bool, elapsed: TimeInterval) {
        guard background, let receipt, receipt.steps > 0 else { return }
        let steps = "\(receipt.steps) step\(receipt.steps == 1 ? "" : "s")"
        transcript.append(ChatMessage(role: .receipt,
                                      text: receipt.stopped ? "Stopped after \(steps) in \(receipt.appName)" : "Done in \(receipt.appName) · \(steps) · \(Int(elapsed))s",
                                      image: peek.frame))
    }

    private func finishRequest() {
        chatBusy = false
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
