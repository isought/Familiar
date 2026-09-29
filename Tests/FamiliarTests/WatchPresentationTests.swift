import Foundation
import Testing
@testable import Familiar

@Suite
@MainActor
struct WatchPresentationTests {
    @Test
    func largeWorkflowReviewStaysCompactAndKeepPreservesTheCompleteDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let workflow = "# Check unread email\n" + String(repeating: "Read a visible message without opening or changing it.\n", count: 2_000) + "END OF COMPLETE WORKFLOW"
        fixture.draft.workflowMarkdown = workflow
        fixture.draft.screensMarkdown = String(repeating: "Inbox details\n", count: 1_000)
        fixture.draft.readingSource = LearnedReadingSource(kind: .mail, name: "Work inbox",
            meaning: "My work email", application: "Google Chrome", bundleID: "com.google.Chrome",
            url: "https://mail.google.com/mail/u/0/#inbox", account: "example@example.test",
            scope: "Only unread email from the last 2 days.",
            navigationHints: String(repeating: "Look for the inbox.\n", count: 1_000),
            completionChecks: "Stop at the saved reading boundary.",
            uncertainties: ["The unread filter was not demonstrated."], requiresReview: true)
        let (assistant, learning) = fixture.makeAssistant()
        try await recordAndStop(learning)
        await (try #require(learning.summarize(purpose: "check unread email"))).value

        let review = try #require(assistant.transcript.last?.text)
        #expect(review.count <= 1_500)
        #expect(review.contains("check unread email"))
        #expect(review.contains("Only unread email from the last 2 days."))
        #expect(review.contains("The unread filter was not demonstrated."))
        #expect(!review.contains("END OF COMPLETE WORKFLOW"))
        #expect(learning.pendingDraft?.workflowMarkdown == workflow)

        await learning.keep()
        #expect(learning.phase == .idle)
        #expect(try String(contentsOf: fixture.workflowFile, encoding: .utf8) == workflow)
    }

    @Test
    func openingTheFullDraftPreservesAllDetailsWithoutKeepingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.draft.workflowMarkdown = String(repeating: "Workflow step\n", count: 1_000) + "WORKFLOW END"
        fixture.draft.screensMarkdown = String(repeating: "Screen detail\n", count: 1_000) + "SCREENS END"
        fixture.draft.glossaryMarkdown = "A term and its complete definition. GLOSSARY END"
        fixture.draft.caveats = ["First caveat", "LAST CAVEAT"]
        fixture.draft.readingSource = LearnedReadingSource(kind: .mail, name: "Work mail",
            meaning: "My incoming work email", bundleID: "com.google.Chrome",
            url: "https://mail.google.com/mail/u/0/#inbox", scope: "Only unread from the last 2 days",
            navigationHints: "NAVIGATION END", completionChecks: "COMPLETION END",
            uncertainties: ["One uncertainty", "LAST UNCERTAINTY"])
        let (assistant, learning) = fixture.makeAssistant()
        var opened: [(String, String)] = []
        assistant.onOpenWatchDraft = { opened.append(($0, $1)) }
        try await recordAndStop(learning)
        await (try #require(learning.summarize(purpose: "Check recent unread email"))).value
        #expect(opened.isEmpty)
        #expect(assistant.suggestions == [Assistant.fullDraftTab, Assistant.keepTab, Assistant.discardTab])
        let transcriptIDs = assistant.transcript.map(\.id)

        assistant.askSuggestion(Assistant.fullDraftTab)
        let document = try #require(opened.first?.1)
        for end in ["WORKFLOW END", "SCREENS END", "GLOSSARY END", "LAST CAVEAT", "NAVIGATION END", "COMPLETION END", "LAST UNCERTAINTY"] {
            #expect(document.contains(end))
        }
        #expect(document.contains("Check recent unread email"))
        #expect(document.contains("Only unread from the last 2 days"))
        #expect(learning.phase == .review)
        #expect(assistant.transcript.map(\.id) == transcriptIDs)
        #expect(!FileManager.default.fileExists(atPath: fixture.workflowFile.path))
        #expect(FileManager.default.fileExists(atPath: fixture.recording.dir.path))

        assistant.askSuggestion(Assistant.discardTab)
        assistant.askSuggestion(Assistant.fullDraftTab)
        #expect(opened.count == 1)
        #expect(!assistant.busy)
        #expect(assistant.question.isEmpty)
    }

    @Test
    func malformedLargeDraftOffersFullOutputAndRetryWithoutDumpingItIntoChat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.draft.parsed = false
        fixture.draft.raw = String(repeating: "Malformed model output\n", count: 2_000) + "RAW END"
        let (assistant, learning) = fixture.makeAssistant()
        var fullOutput = ""
        assistant.onOpenWatchDraft = { _, document in fullOutput = document }
        try await recordAndStop(learning)
        await (try #require(learning.summarize(purpose: "Check mail"))).value
        #expect(assistant.suggestions == [Assistant.fullDraftTab, Assistant.retryTab, Assistant.discardTab])
        #expect(assistant.transcript.last!.text.count <= 1_500)
        #expect(!assistant.transcript.last!.text.contains("RAW END"))
        assistant.askSuggestion(Assistant.fullDraftTab)
        #expect(fullOutput.contains(fixture.draft.raw))
        #expect(learning.phase == .failed)

        fixture.draft.parsed = true
        await (try #require(learning.retry())).value
        #expect(assistant.suggestions == [Assistant.fullDraftTab, Assistant.keepTab, Assistant.discardTab])
    }

    @Test
    func keepingLongGeneratedMetadataAlsoLeavesABoundedReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let long = String(repeating: "Generated detail\n", count: 1_000)
        fixture.draft.packName = long
        fixture.draft.workflowTitle = long
        fixture.draft.matchURLs = [long]
        fixture.draft.readingSource = LearnedReadingSource(kind: .mail, name: long, meaning: "Work mail", bundleID: "com.google.Chrome")
        let (assistant, learning) = fixture.makeAssistant()
        try await recordAndStop(learning)
        await (try #require(learning.summarize(purpose: nil))).value
        await learning.keep()
        let receipt = try #require(assistant.transcript.last?.text)
        #expect(receipt.count <= 1_500)
        #expect(receipt.components(separatedBy: "\n").count < 20)
        #expect(assistant.transcript.first { $0.role == .learned }?.text.count ?? 0 <= 100)
        #expect(try String(contentsOf: fixture.workflowFile, encoding: .utf8) == fixture.draft.workflowMarkdown)
    }

    @Test
    func summaryBoundsEveryGeneratedFieldIncludingMultiLineValues() {
        let long = String(repeating: "Detail\n", count: 1_000)
        var draft = PackDraft(packName: long, packDescription: long, workflowTitle: long, workflowMarkdown: long,
                              screensMarkdown: long, glossaryMarkdown: long, caveats: [long, long], parsed: true)
        func check() {
            let summary = Assistant.draftBody(draft, purpose: long, context: long, root: URL(fileURLWithPath: "/unused"))
            #expect(summary.count <= 1_500)
            #expect(summary.components(separatedBy: "\n").count < 30)
            #expect(summary.hasSuffix("Open full draft for complete instructions and any shortened details."))
        }
        check()
        draft.readingSource = LearnedReadingSource(kind: .mail, name: long, meaning: long, application: long,
            bundleID: long, url: long, account: long, scope: long, navigationHints: long,
            completionChecks: long, uncertainties: [long, long], requiresReview: true)
        check()
        draft.readingSource = nil
        draft.calendarSource = LearnedCalendarSource(name: long, meaning: long, application: long, bundleID: long,
            url: long, account: long, calendarName: long, timeZoneID: long, navigationHints: long,
            completionChecks: long, uncertainties: [long, long])
        check()
    }

    @Test
    func descriptionThenContextGeneratesOneDraftAndReviewKeepsItsTabs() async throws {
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
        #expect(learning.awaitingContext)
        #expect(!assistant.busy)
        #expect(fixture.summaryRequests.isEmpty)
        #expect(assistant.suggestions == [Assistant.skipContextTab, Assistant.discardTab])
        #expect(assistant.transcript.last?.text.contains("Any rules or limits") == true)
        #expect(learning.pendingRecording?.meta.purpose == "Submit the travel expense")

        let context = "Use the client travel category. Stop before submitting."
        assistant.question = context
        assistant.ask()
        await gate.entered()
        #expect(assistant.busy)
        #expect(assistant.question.isEmpty)
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.transcript.last?.role == .user)
        #expect(fixture.summaryRequests.count == 1)
        #expect(fixture.summaryRequests.first?.0.meta.context == context)
        #expect(fixture.summaryRequests.first?.1 == "Submit the travel expense")

        // A stale Skip action while generation is running cannot submit a second request.
        assistant.askSuggestion(Assistant.skipContextTab)

        gate.finish(fixture.draft)
        await fixture.events.waitFor("draft")
        #expect(!assistant.busy)
        #expect(assistant.pendingDraft?.workflowTitle == "Submit an expense")
        #expect(!assistant.transcript.contains { $0.role == .user && $0.text == "Submit the travel expense" })
        #expect(!assistant.transcript.contains { $0.role == .user && $0.text == context })
        #expect(assistant.transcript.suffix(2).map(\.role) == [.draft, .assistant])
        #expect(assistant.transcript.last?.text.contains("You said: “Submit the travel expense”") == true)
        #expect(assistant.transcript.last?.text.contains(context) == true)
        #expect(assistant.suggestions == [Assistant.fullDraftTab, Assistant.keepTab, Assistant.discardTab])
        #expect(assistant.status.contains("confidence 80%"))
        var fullDraft = ""
        assistant.onOpenWatchDraft = { _, text in fullDraft = text }
        assistant.askSuggestion(Assistant.fullDraftTab)
        #expect(fullDraft.contains(context))
        #expect(fixture.summaryRequests.count == 1)
    }

    @Test
    func skippingContextIsOptionalAndStaleDescriptionClicksDoNotSkipIt() async throws {
        for skipDescription in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let (assistant, learning) = fixture.makeAssistant()
            try await recordAndStop(learning)
            assistant.question = "Check email"
            if skipDescription { assistant.askSuggestion(Assistant.continueTab) }
            else { assistant.ask() }
            #expect(learning.awaitingContext)
            #expect(assistant.question.isEmpty)
            #expect(fixture.summaryRequests.isEmpty)
            let before = assistant.transcript.map(\.id)
            assistant.askSuggestion(Assistant.continueTab)
            #expect(learning.awaitingContext)
            #expect(assistant.transcript.map(\.id) == before)

            assistant.question = "An unsent context that I chose to skip"
            assistant.askSuggestion(Assistant.skipContextTab)
            assistant.askSuggestion(Assistant.skipContextTab)
            await fixture.events.waitFor("draft")
            #expect(assistant.question.isEmpty)
            #expect(fixture.summaryRequests.count == 1)
            #expect(fixture.summaryRequests.first?.0.meta.context == nil)
            #expect(fixture.summaryRequests.first?.0.meta.purpose == (skipDescription ? nil : "Check email"))
            #expect(learning.phase == .review)
        }
    }

    @Test
    func clearingOrDiscardingAtContextStopsTheTeachingFlowAndBlocksThePen() async throws {
        for discard in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let (assistant, learning) = fixture.makeAssistant()
            var penStarts = 0
            assistant.onStartWand = { penStarts += 1 }
            try await recordAndStop(learning)
            assistant.question = "Check email"
            assistant.ask()
            assistant.startWand()
            #expect(penStarts == 0)
            #expect(learning.awaitingContext)
            if discard { assistant.askSuggestion(Assistant.discardTab) }
            else { assistant.clearConversation() }
            assistant.askSuggestion(Assistant.skipContextTab)
            #expect(fixture.summaryRequests.isEmpty)
            #expect(!learning.hasPendingReview)
            #expect(assistant.suggestions.isEmpty)
            #expect(!assistant.busy)
        }
    }

    @Test
    func metadataFailureKeepsTheTypedDescriptionOrContextAvailableToRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (assistant, learning) = fixture.makeAssistant()
        try await recordAndStop(learning)
        fixture.metadataFails = true
        assistant.question = "Check email"
        assistant.ask()
        #expect(learning.awaitingPurpose)
        #expect(assistant.question == "Check email")
        #expect(assistant.suggestions == [Assistant.continueTab, Assistant.discardTab])
        fixture.metadataFails = false
        assistant.ask()
        #expect(learning.awaitingContext)

        fixture.metadataFails = true
        assistant.question = "Only unread from the last 2 days"
        assistant.ask()
        #expect(learning.awaitingContext)
        #expect(assistant.question == "Only unread from the last 2 days")
        #expect(assistant.suggestions == [Assistant.skipContextTab, Assistant.discardTab])
        #expect(fixture.summaryRequests.isEmpty)
        fixture.metadataFails = false
        assistant.ask()
        await fixture.events.waitFor("draft")
        #expect(fixture.summaryRequests.count == 1)
        #expect(fixture.summaryRequests.first?.0.meta.context == "Only unread from the last 2 days")
        #expect(assistant.question.isEmpty)
    }

    @Test
    func longContextStaysCompactInChatAndCompleteInTheGenerationAndReview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate<PackDraft>()
        fixture.summaryGate = gate
        let (assistant, learning) = fixture.makeAssistant()
        let context = String(repeating: "A detailed exception and rule.\n", count: 2_000) + "CONTEXT END"
        try await recordAndStop(learning)
        assistant.question = "Check email"
        assistant.ask()
        assistant.question = context
        assistant.ask()
        await gate.entered()
        #expect(assistant.transcript.last?.text.count ?? 0 <= 220)
        #expect(fixture.summaryRequests.first?.0.meta.context == context)
        gate.finish(fixture.draft)
        await fixture.events.waitFor("draft")
        #expect(assistant.transcript.last?.text.count ?? 0 <= 1_500)
        #expect(!assistant.transcript.contains { $0.text.contains("CONTEXT END") })
        var document = ""
        assistant.onOpenWatchDraft = { _, text in document = text }
        assistant.askSuggestion(Assistant.fullDraftTab)
        #expect(document.contains(context))
    }

    @Test
    func failedSummaryOffersRetryAndKeptDraftBecomesLearned() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (assistant, learning) = fixture.makeAssistant()
        try await recordAndStop(learning)
        fixture.summaryFails = true
        assistant.askSuggestion(Assistant.continueTab)
        assistant.askSuggestion(Assistant.skipContextTab)
        await fixture.events.waitFor("failed")
        #expect(assistant.transcript.last?.role == .error)
        #expect(assistant.suggestions == [Assistant.retryTab, Assistant.discardTab])
        #expect(!assistant.busy)

        fixture.summaryFails = false
        assistant.askSuggestion(Assistant.retryTab)
        await fixture.events.waitFor("draft")
        #expect(assistant.suggestions == [Assistant.fullDraftTab, Assistant.keepTab, Assistant.discardTab])
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
    func discardAfterPartialKeepAcknowledgesTheFilesThatRemainSaved() async throws {
        for sourceFailure in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.draft.calendarSource = LearnedCalendarSource(name: "Work calendar", meaning: "My work schedule", bundleID: "com.apple.iCal")
            fixture.sourceFails = sourceFailure
            fixture.reloadFails = !sourceFailure
            let (assistant, learning) = fixture.makeAssistant()
            try await recordAndStop(learning)
            let summary = try #require(learning.summarize(purpose: "My work calendar"))
            await summary.value
            await learning.keep()
            #expect(learning.phase == .review)
            #expect(FileManager.default.fileExists(atPath: fixture.workflowFile.path))

            assistant.askSuggestion(Assistant.discardTab)
            let receipt = try #require(assistant.transcript.last?.text)
            #expect(receipt.contains("already saved and remain on disk"))
            #expect(receipt.contains(fixture.workflowFile.path))
            #expect(!receipt.contains("nothing was saved"))
            #expect(FileManager.default.fileExists(atPath: fixture.workflowFile.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.recording.dir.path))
            #expect(!learning.hasPendingReview)
        }
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
                #expect(assistant.transcript.last?.text.contains("short name or description") == true)
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

    private enum Failure: Error { case model, reload, source, metadata }

    @MainActor
    private final class Fixture {
        let root: URL
        let recording: Recording
        let events = Events()
        var draft = PackDraft(packDir: "expenses", packName: "Expenses", matchURLs: ["expenses.example.test"],
                              workflowSlug: "submit", workflowTitle: "Submit an expense", workflowMarkdown: "# Submit\nPress Save.",
                              confidence: 0.8, parsed: true)
        var summaryGate: Gate<PackDraft>?
        var stopGate: Gate<Recording>?
        var summaryFails = false
        var reloadFails = false
        var sourceFails = false
        var metadataFails = false
        var summaryRequests: [(Recording, String?)] = []
        var workflowFile: URL { root.appendingPathComponent("tools/expenses/docs/workflows/submit.md") }

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
                summarize: { recording, purpose, _ in
                    self.summaryRequests.append((recording, purpose))
                    if let gate = self.summaryGate { return await gate.wait() }
                    if self.summaryFails { throw Failure.model }
                    return self.draft
                },
                write: { draft in
                    let file = registry.root.appendingPathComponent("\(draft.packDir)/docs/workflows/\(draft.workflowSlug).md")
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try draft.workflowMarkdown.write(to: file, atomically: true, encoding: .utf8)
                    return [file]
                },
                reload: { if self.reloadFails { throw Failure.reload } },
                saveSource: { _ in if self.sourceFails { throw Failure.source } },
                saveMeta: { recording in
                    if self.metadataFails { throw Failure.metadata }
                    try recording.saveMeta()
                }
            ))
            let assistant = Assistant(config: config, watcher: ContextWatcher(), registry: registry, shell: ShellState(), learning: learning)
            let present = learning.onEvent
            learning.onEvent = { present?($0); self.events.received($0) }
            return (assistant, learning)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
