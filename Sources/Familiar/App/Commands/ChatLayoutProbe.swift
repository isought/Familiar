#if DEBUG
import AppKit
import FamiliarContracts
import FamiliarRuntime
import Foundation
import SwiftUI

/// Exercises the actual chat view while transcript shape, answer reveal and bottom scrolling change.
/// No provider or desktop tools run; all text and the isolated app home are synthetic.
@MainActor
enum ChatLayoutProbe {
    static func run() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await exerciseConversation()
                progress("conversation completed and chat responsive")
                exit(0)
            } catch {
                progress("probe failed: \(error)")
                exit(1)
            }
        }
        progress("starting NSApplication.run")
        NSApp.run()
        exit(1)
    }

    private static func exerciseConversation() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FAMILIAR_BUBBLE_LAYOUT_FIXTURE"]!)
        var config = Config()
        config.apiKey = "layout-fixture-no-network"
        config.screenshotMode = "auto"
        let shell = ShellState()
        shell.cardSize = BubblePanel.defaultExpandedSize
        let watcher = ContextWatcher()
        let registry = ToolRegistry(root: root.appendingPathComponent("tools"), runner: ScriptRunner(config: config))
        let learning = WatchLearnComposition.make(recorder: WatchRecorder(config: config, watcher: watcher),
            registry: registry, activities: NativeActivityGate(), config: { config })
        let state = Assistant(config: config, watcher: watcher, registry: registry, shell: shell, learning: learning)
        let store = MorningStore(directory: root.appendingPathComponent("morning"))
        let card = MorningCard(folderID: store.folders[0].id, title: "Review the CVS settlement notice",
            action: MorningAction(title: "Prepare a summary", instruction: "Summarize the saved settlement notice"))
        try store.saveCard(card)
        state.cardConversation = CardConversation(store: store)
        state.contextLine = "Discussing a morning card"
        let hosting = NSHostingView(rootView: BubbleView(state: state, shell: shell))
        let window = BubblePanel(hideFromScreenShare: true)
        window.contentView = hosting
        let onScreen = ProcessInfo.processInfo.environment["FAMILIAR_LAYOUT_ONSCREEN"] == "1"
        let origin: NSPoint
        if onScreen, let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24)
            window.level = .normal
        } else { origin = NSPoint(x: -10000, y: -10000) }
        progress("window mode: \(onScreen ? "on screen, behind existing windows" : "off screen")")
        window.setFrameOrigin(origin)
        window.orderBack(nil)
        defer { window.close() }
        shell.expanded = true
        window.setFrame(NSRect(origin: origin, size: shell.cardSize), display: true)
        if onScreen { window.makeKey() }
        hosting.layoutSubtreeIfNeeded()
        try await settle(hosting, phase: "empty chat", milliseconds: 350)

        let replayPath = ProcessInfo.processInfo.environment["FAMILIAR_LAYOUT_REPLY_FILE"]
        let replayText = try replayPath.map { try String(contentsOfFile: $0, encoding: .utf8) }
        let shapes = replayText == nil ? Array(0..<3) : [0]
        for shape in shapes {
            state.clearConversation()
            if shape == 2 {
                state.transcript = [ChatMessage(role: .user, text: "What should I review this morning?"),
                    ChatMessage(role: .assistant, text: "You have two saved cards to review. Choose one to discuss its suggested action.")]
            }
            _ = state.discussCard(card)
            try await settle(hosting, phase: "card invitation \(shape)", milliseconds: 350)
            try await submitSyntheticQuestion("What should I do?", to: state, hosting: hosting)
            let text = replayText ?? response(shape: shape)
            let result = try await state.execution.run(client: FixtureClient(text: text),
                content: [["type": "text", "text": "Synthetic question"]], prepareImages: false,
                prepare: { PreparedExecution(system: "Synthetic fixture", router: try ToolRouter(routes: [])) })
            state.presentExecutionResult(result)
            state.chatBusy = false
            progress("reply \(shape): \(text.count) characters, \(text.components(separatedBy: "\n").count) lines")
            try await settle(hosting, phase: "analysis reply \(shape)", milliseconds: 1900)
            try await submitSyntheticQuestion("do you think it's worth the effort", to: state, hosting: hosting)
            try await settle(hosting, phase: "exact follow-up \(shape)", milliseconds: 600)
            state.chatBusy = false
        }
        state.question = "The input remains editable after several long answers."
        try await settle(hosting, phase: "final input update", milliseconds: 350)
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("chat.png"))
        }
    }

    private static func settle(_ hosting: NSView, phase: String, milliseconds: Int) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(milliseconds))
        hosting.layoutSubtreeIfNeeded()
        progress("responsive after \(phase)")
    }

    private static func submitSyntheticQuestion(_ question: String, to state: Assistant, hosting: NSView) async throws {
        state.question = question
        try await settle(hosting, phase: "typing question", milliseconds: 150)
        progress("submitting question")
        // Match ask()'s visible mutations and its asynchronous send preparation without making a provider call.
        state.question = ""
        state.transcript.append(ChatMessage(role: .user, text: question))
        state.chatBusy = true
        await Task.yield()
        state.suggestions = []
        state.status = "Thinking…"
        try await settle(hosting, phase: "submitted question", milliseconds: 250)
    }

    private static func response(shape: Int) -> String {
        let sections = (1...(shape == 0 ? 2 : 4)).map { index in
            """
            **\(index). Consider the current evidence.** The saved scan observed the notice in your inbox. It gives us the sender, the subject, and a short preview, but it does not establish that you must act. Keep the card until you review the details and decide whether the suggested next step is useful.
            - Check the [original notice](https://example.test/messages/thread-20260928-0001?source=inbox&view=conversation&tracking=long-stable-identifier-000\(index)) and its visible deadline.
            - Your previous adjustment stays attached when the next scan updates the card.
            """
        }
        let answer = "Here is what this card means and what you can do next.\n\n" + sections.joined(separator: "\n\n")
            + "\n\nI can help prepare a draft. You can review it before deciding whether to use it."
        return (shape == 2 ? answer.replacingOccurrences(of: "\n", with: " ") : answer)
            + "\nSuggestions: Explain the deadline | Keep this for tomorrow | Change the proposed action"
    }

    private final class FixtureClient: ConversationClient {
        var effort = "low"
        var maxTokens = 2_000
        var maxToolRounds = 0
        var shouldStop: () -> Bool = { false }
        let text: String
        init(text: String) { self.text = text }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            ClaudeReply(text: text, inputTokens: 4666, outputTokens: 639, cacheRead: 0, toolCalls: 0)
        }
    }

    private static func progress(_ text: String) {
        FileHandle.standardOutput.write(Data("CHAT LAYOUT: \(text)\n".utf8))
    }
}
#endif
