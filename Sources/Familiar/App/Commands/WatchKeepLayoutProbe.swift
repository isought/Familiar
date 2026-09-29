#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Isolated, synthetic app-lifecycle probe used by the subprocess regression.
/// It never records the desktop, contacts a provider, or loads the user's data.
@MainActor
enum WatchKeepLayoutProbe {
    static func run() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await exerciseKeepInHostedChat()
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

    @MainActor private static func exerciseKeepInHostedChat() async throws {
        let root = URL(fileURLWithPath: try require(ProcessInfo.processInfo.environment["FAMILIAR_BUBBLE_LAYOUT_FIXTURE"]))
        let recordingDirectory = root.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        let recording = Recording(dir: recordingDirectory,
            events: [WatchEvent(index: 0, t: 0, kind: "click", label: "Inbox")],
            meta: WatchMeta(startedAt: "2026-09-28", clicks: 3))
        let source = LearnedReadingSource(kind: .mail, name: "Example Gmail inbox",
            meaning: "My work inbox and the messages I should review this morning.", application: "Google Chrome",
            bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox", account: "example@example.test",
            scope: "Read only the first visible page of Primary. Collect visible senders, subjects, dates and snippets; do not open or change messages.",
            navigationHints: "Confirm the account and selected Inbox, then read each visible row in Primary.",
            completionChecks: "Every row on the first visible page is checked, with uncertain or inaccessible information reported explicitly.",
            uncertainties: ["The source address was seen in a screenshot rather than the event log. Confirm it before a later read.",
                            "The recording did not establish whether the same account is selected in another browser window."],
            requiresReview: true)
        let steps = (1...800).map { "\($0). Read the visible inbox row, preserving the sender, subject, date and snippet. Record any uncertainty without opening the message or changing its read status." }
        let notes = (1...6).map { "- Note \($0): Confirm the account and selected Inbox before recording current messages. Keep the same first-page boundary and report any information that cannot be verified." }
        let draft = PackDraft(packDir: "example-mail", packName: "Example Gmail", matchTitles: ["Gmail"],
            workflowSlug: "read-inbox", workflowTitle: "Check the Gmail inbox", workflowMarkdown: "# Read the inbox\n" + steps.joined(separator: "\n") + "\n\n## Notes\n" + notes.joined(separator: "\n") + "\nEND OF COMPLETE WORKFLOW",
            screensMarkdown: "# Inbox\n" + Array(repeating: "Confirm Primary is selected and the expected account is visible. Read only the sender, subject, snippet and visible date for each message.", count: 10).joined(separator: "\n"),
            caveats: ["The demonstration is an example. Collect current observations during a later read."], confidence: 0.9, parsed: true,
            readingSource: source)
        var config = Config()
        config.apiKey = "layout-fixture-no-network"
        config.screenshotMode = "never"
        let registry = ToolRegistry(root: root.appendingPathComponent("tools"), runner: ScriptRunner(config: config))
        let reviewCharacters = Assistant.draftBody(draft, purpose: "check unread email", root: registry.root, teachingCalendar: true).count
        let userContext = "Read only the first visible page. Do not open messages or change their read status."
        var summaryCalls = 0
        let learning = WatchLearnSession(operations: .init(start: { _ in }, stop: { recording }, abandon: {},
            summarize: { recorded, _, _ in
                summaryCalls += 1
                try ensure(recorded.meta.purpose == "check unread email" && recorded.meta.context == userContext)
                try await Task.sleep(for: .milliseconds(200))
                return draft
            }, write: {
                let files = try PackWriter.write($0, root: registry.root)
                progress("workflow written")
                return files
            }, reload: {
                progress("reload suspended while saving is visible")
                try await Task.sleep(for: .milliseconds(800))
                progress("reload resumed on main actor")
            }))
        let shell = ShellState()
        shell.cardSize = BubblePanel.defaultExpandedSize
        let assistant = Assistant(config: config, watcher: ContextWatcher(), registry: registry, shell: shell, learning: learning)
        let draftWindow = WatchDraftWindowController(initialFrame: NSRect(x: -10000, y: -10000, width: 780, height: 680))
        defer { draftWindow.close() }
        var fullReview = ""
        assistant.onOpenWatchDraft = { title, markdown in
            fullReview = markdown
            draftWindow.show(title: title, markdown: markdown, hideFromScreenShare: true)
        }
        let hosting = NSHostingView(rootView: BubbleView(state: assistant, shell: shell))
        let window = BubblePanel(hideFromScreenShare: true)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        flushUI(for: 0.5)
        shell.expanded = true
        window.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: shell.cardSize), display: true)
        try ensure(try learning.start(source: true))
        await (try require(learning.stop())).value
        // A person can only submit the description after its prompt has appeared.
        try await Task.sleep(for: .milliseconds(1700))
        assistant.question = "check unread email"
        assistant.ask()
        try ensure(learning.awaitingContext && !assistant.busy && summaryCalls == 0)
        try ensure(assistant.suggestions == [Assistant.skipContextTab, Assistant.discardTab])
        flushUI(for: 1)
        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("context.png"))
        }
        assistant.question = userContext
        assistant.ask()
        let draftDeadline = Date().addingTimeInterval(4)
        while learning.phase == .summarizing && Date() < draftDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try ensure(learning.phase == .review)
        try ensure(summaryCalls == 1)
        try ensure(assistant.suggestions.contains(Assistant.keepTab))
        try ensure(reviewCharacters <= 1_500)
        try ensure(assistant.transcript.last?.text.contains("END OF COMPLETE WORKFLOW") == false)
        assistant.askSuggestion(Assistant.fullDraftTab)
        try ensure(fullReview.contains(draft.workflowMarkdown))
        try ensure(fullReview.contains(userContext))
        try ensure(learning.phase == .review)
        let reviewWindow = try require(draftWindow.window)
        let reviewScroll = try require(reviewWindow.contentView as? NSScrollView)
        let reviewText = try require(reviewScroll.documentView as? NSTextView)
        try ensure(reviewText.string == fullReview && !reviewText.isEditable && reviewText.isSelectable)
        try ensure(reviewText.usesFindBar && reviewWindow.sharingType == .none)
        reviewScroll.layoutSubtreeIfNeeded()
        if let bitmap = reviewScroll.bitmapImageRepForCachingDisplay(in: reviewScroll.bounds) {
            reviewScroll.cacheDisplay(in: reviewScroll.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("full-draft.png"))
        }
        reviewText.scrollRangeToVisible(NSRange(location: (fullReview as NSString).length - 1, length: 1))
        reviewScroll.layoutSubtreeIfNeeded()
        draftWindow.close()
        assistant.askSuggestion(Assistant.fullDraftTab)
        try ensure(draftWindow.window === reviewWindow && reviewText.string == fullReview)
        draftWindow.close()
        progress("long document ready: \(draft.workflowMarkdown.count) characters; compact review: \(reviewCharacters) characters")
        flushUI(for: 2)
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("draft.png"))
        }
        progress("host \(hosting.frame), window \(window.frame), visible \(window.isVisible); fixture \(root.path)")
        progress("draft rendered; pressing Keep")
        assistant.askSuggestion(Assistant.keepTab)
        try await Task.sleep(for: .milliseconds(30))
        try ensure(learning.phase == .saving)
        flushUI(for: 1.2)
        try await Task.sleep(for: .milliseconds(1500))
        try ensure(learning.phase == .idle)
        try ensure(!assistant.busy)
        try ensure(summaryCalls == 1)
        try ensure(assistant.transcript.contains { $0.role == .learned })
        let saved = try String(contentsOf: registry.root.appendingPathComponent("example-mail/docs/workflows/read-inbox.md"), encoding: .utf8)
        try ensure(saved.contains(draft.workflowMarkdown))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        progress("keep completed and chat responsive")
    }

    private static func progress(_ text: String) {
        FileHandle.standardOutput.write(Data("LAYOUT: \(text)\n".utf8))
    }

    @MainActor private static func flushUI(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Failure: Error { let message: String }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "A required probe value was missing.") }
        return value
    }

    private static func ensure(_ value: @autoclosure () throws -> Bool) throws {
        guard try value() else { throw Failure(message: "The expected Watch Me state was not reached.") }
    }
}
#endif
