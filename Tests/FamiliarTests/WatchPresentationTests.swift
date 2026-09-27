import Foundation
import Testing
@testable import Familiar

@Suite
@MainActor
struct WatchPresentationTests {
    @Test
    func typedPurposeBecomesDraftContentAndReviewKeepsItsTabs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate<PackDraft>()
        fixture.summaryGate = gate
        let (assistant, learning) = fixture.makeAssistant()
        try await recordAndStop(learning)
        #expect(assistant.shell.expanded)
        #expect(assistant.suggestions == [Assistant.continueTab, Assistant.discardTab])
        assistant.question = "Submit the travel expense"
        assistant.ask()
        await gate.entered()
        #expect(assistant.busy)
        #expect(assistant.question.isEmpty)
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.transcript.last?.role == .user)

        gate.finish(fixture.draft)
        await fixture.events.waitFor("draft")
        #expect(!assistant.busy)
        #expect(assistant.pendingDraft?.workflowTitle == "Submit an expense")
        #expect(!assistant.transcript.contains { $0.role == .user && $0.text == "Submit the travel expense" })
        #expect(assistant.transcript.suffix(2).map(\.role) == [.draft, .assistant])
        #expect(assistant.transcript.last?.text.contains("You said: “Submit the travel expense”") == true)
        #expect(assistant.suggestions == [Assistant.keepTab, Assistant.discardTab])
        #expect(assistant.status.contains("confidence 80%"))
    }

    @Test
    func failedSummaryOffersRetryAndKeptDraftBecomesLearned() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (assistant, learning) = fixture.makeAssistant()
        try await recordAndStop(learning)
        fixture.summaryFails = true
        assistant.askSuggestion(Assistant.continueTab)
        await fixture.events.waitFor("failed")
        #expect(assistant.transcript.last?.role == .error)
        #expect(assistant.suggestions == [Assistant.retryTab, Assistant.discardTab])
        #expect(!assistant.busy)

        fixture.summaryFails = false
        assistant.askSuggestion(Assistant.retryTab)
        await fixture.events.waitFor("draft")
        #expect(assistant.suggestions == [Assistant.keepTab, Assistant.discardTab])
        assistant.askSuggestion(Assistant.keepTab)
        await fixture.events.waitFor("kept")
        #expect(assistant.transcript.contains { $0.role == .learned && $0.text == "Submit an expense" })
        #expect(assistant.transcript.last?.text.contains("Kept as Expenses.") == true)
        #expect(assistant.transcript.last?.text.contains("- docs/workflows/submit.md") == true)
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.pendingDraft == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.recording.dir.path))
    }

    @Test
    func clearOrDiscardPreventsLateDraftFromReturningToThePad() async throws {
        for discard in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let gate = Gate<PackDraft>()
            fixture.summaryGate = gate
            let (assistant, learning) = fixture.makeAssistant()
            try await recordAndStop(learning)
            let pending = try #require(learning.summarize(purpose: "Discarded work"))
            await gate.entered()
            if discard { learning.discard() } else { assistant.clearConversation() }
            assistant.shell.expanded = false
            let remaining = assistant.transcript.map(\.id)
            gate.finish(fixture.draft)
            await pending.value

            #expect(assistant.transcript.map(\.id) == remaining)
            #expect(!assistant.shell.expanded)
            #expect(assistant.pendingDraft == nil)
            #expect(assistant.suggestions.isEmpty)
            #expect(assistant.status.isEmpty)
            #expect(!assistant.busy)
            if discard {
                #expect(assistant.transcript.last?.text == "Discarded. The recording was deleted and nothing was saved.")
            } else { #expect(assistant.transcript.isEmpty) }
        }
    }

    @Test
    func chatDefersPurposeAndClearingTheDeferredRecordingPreventsResurrection() async throws {
        for clear in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let (assistant, learning) = fixture.makeAssistant()
            assistant.chatBusy = true
            try await recordAndStop(learning)
            #expect(learning.phase == .waitingForDelivery)
            #expect(assistant.transcript.isEmpty)
            #expect(!assistant.shell.expanded)
            if clear { assistant.clearConversation() }
            assistant.chatBusy = false

            if clear {
                #expect(assistant.transcript.isEmpty)
                #expect(assistant.suggestions.isEmpty)
                #expect(!assistant.shell.expanded)
            } else {
                #expect(assistant.transcript.count == 1)
                #expect(assistant.transcript.last?.text.contains("What were you doing?") == true)
                #expect(assistant.suggestions == [Assistant.continueTab, Assistant.discardTab])
                #expect(assistant.shell.expanded)
            }
        }
    }

    @Test
    func clearingADrainingStopRestoresTheIdleContextLabel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate<Recording>()
        fixture.stopGate = gate
        let (assistant, learning) = fixture.makeAssistant()
        #expect(try learning.start())
        let stopping = try #require(learning.stop())
        await gate.entered()
        assistant.clearConversation()
        #expect(assistant.watching)
        gate.finish(fixture.recording)
        await stopping.value

        #expect(!assistant.watching)
        #expect(assistant.transcript.isEmpty)
        #expect(assistant.contextLine == "Watcher off")
    }

    private func recordAndStop(_ learning: WatchLearnSession) async throws {
        #expect(try learning.start())
        let task = try #require(learning.stop())
        await task.value
    }

    @MainActor
    private final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Never>?
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async -> Value {
            await withCheckedContinuation {
                continuation = $0
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
            }
        }

        func entered() async {
            if continuation != nil { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish(_ value: Value) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: value)
        }
    }

    @MainActor
    private final class Events {
        private var names: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func received(_ event: WatchLearnSession.Event) {
            let name: String
            switch event {
            case .draftReady: name = "draft"
            case .kept: name = "kept"
            case .failed: name = "failed"
            default: return
            }
            names.insert(name)
            for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.resume() }
        }

        func waitFor(_ name: String) async {
            if names.contains(name) { return }
            await withCheckedContinuation { waiters[name, default: []].append($0) }
        }
    }

    private enum Failure: Error { case model }

    @MainActor
    private final class Fixture {
        let root: URL
        let recording: Recording
        let events = Events()
        let draft = PackDraft(packDir: "expenses", packName: "Expenses", matchURLs: ["expenses.example.test"],
                              workflowSlug: "submit", workflowTitle: "Submit an expense", workflowMarkdown: "# Submit\nPress Save.",
                              confidence: 0.8, parsed: true)
        var summaryGate: Gate<PackDraft>?
        var stopGate: Gate<Recording>?
        var summaryFails = false

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-watch-presentation-\(UUID().uuidString)")
            let dir = root.appendingPathComponent("recording")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            recording = Recording(dir: dir, events: [WatchEvent(index: 0, t: 0, kind: "click")],
                                  meta: WatchMeta(startedAt: "2026-01-01", clicks: 1))
        }

        func makeAssistant() -> (Assistant, WatchLearnSession) {
            var config = Config()
            config.apiKey = "fixture-not-for-network"
            config.screenshotMode = "never"
            let registry = ToolRegistry(root: root.appendingPathComponent("tools"), runner: ScriptRunner(config: config))
            let learning = WatchLearnSession(operations: .init(
                start: { _ in },
                stop: { if let gate = self.stopGate { return await gate.wait() }; return self.recording },
                abandon: {},
                summarize: { _, _, _ in
                    if let gate = self.summaryGate { return await gate.wait() }
                    if self.summaryFails { throw Failure.model }
                    return self.draft
                },
                write: { draft in [registry.root.appendingPathComponent("\(draft.packDir)/docs/workflows/\(draft.workflowSlug).md")] },
                reload: {}
            ))
            let assistant = Assistant(config: config, watcher: ContextWatcher(), registry: registry, shell: ShellState(), learning: learning)
            let present = learning.onEvent
            learning.onEvent = { present?($0); self.events.received($0) }
            return (assistant, learning)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
