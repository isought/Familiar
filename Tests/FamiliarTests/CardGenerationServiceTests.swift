import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct CardGenerationServiceTests {
    @Test func savedObservationsBecomeCardsThroughTheExecutorWithoutExecutingTheirActions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runID = try fixture.save("Review the contract by Friday", at: Date())
        var calls = 0
        let service = fixture.service { _, tools, messages, executor in
            calls += 1
            #expect(tools.compactMap { $0["name"] as? String } == [CardGenerationSubmission.toolName])
            #expect(!fixture.desktop.isBusy)
            #expect(fixture.desktop.tasks.activeTask != nil)
            let key = try Self.key(in: messages)
            let result = await executor(CardGenerationSubmission.toolName, ["proposals": [Self.proposal(key)]], nil)
            #expect(!result.isError)
            #expect(fixture.morning.cards.isEmpty, "Submission stages data until the executor finishes successfully")
            return "Ready"
        }
        await service.generate(runID: runID)?.value
        #expect(service.error == nil)
        #expect(fixture.morning.cards.count == 1)
        #expect(fixture.morning.cards.first?.tracking?.itemKey == "thread-123")
        #expect(fixture.morning.workItems.isEmpty)
        #expect(fixture.desktop.tasks.history.first?.outcome == .completed)
        #expect(service.generate(runID: runID) == nil)
        let reopened = MorningStore(directory: fixture.root.appendingPathComponent("morning"))
        let restarted = CardGenerationService(morning: reopened, sources: fixture.sources,
            desktop: fixture.desktop, config: { Config() }, makeClient: { _ in
                calls += 1
                return nil
            })
        restarted.start()
        #expect(!restarted.isRunning)
        #expect(calls == 1)
        #expect(reopened.cards == fixture.morning.cards)
    }

    @Test func changedEvidenceUpdatesTheSameCardKeepsHumanContextAndExplicitResolutionClosesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        _ = try fixture.save("Review the contract by Friday", at: now)
        var calls = 0
        let service = fixture.service { system, _, messages, executor in
            calls += 1
            #expect(system.contains("never"))
            let text = Self.messageText(messages)
            if calls == 2 { #expect(text.contains("Ask Maya before drafting")) }
            let proposals: [[String: Any]] = calls == 3 ? [] : [Self.proposal(try Self.key(in: messages), title: calls == 1 ? "Review contract" : "Contract deadline changed")]
            let result = await executor(CardGenerationSubmission.toolName, ["proposals": proposals], nil)
            #expect(!result.isError)
            return "Ready"
        }
        await service.generate()?.value
        let original = try #require(fixture.morning.cards.first)
        try fixture.morning.setDisposition(cardID: original.id, to: .mine)
        try fixture.morning.updateCardContext(cardID: original.id, context: "Ask Maya before drafting")
        _ = try fixture.save("The deadline moved to Monday", at: now.addingTimeInterval(60))
        await service.generate()?.value
        let updated = try #require(fixture.morning.cards.first)
        #expect(fixture.morning.cards.count == 1)
        #expect(updated.id == original.id)
        #expect(updated.disposition == .mine)
        #expect(updated.personalContext == "Ask Maya before drafting")
        #expect(updated.sources.first?.excerpt.contains("Monday") == true)
        _ = try fixture.save("Contract signed; no further review needed", at: now.addingTimeInterval(120), state: .resolved)
        await service.generate()?.value
        let resolved = try #require(fixture.morning.cards.first)
        #expect(resolved.id == original.id)
        #expect(resolved.isResolved)
        #expect(resolved.tracking?.resolutionEvidence.contains("Contract signed") == true)
        #expect(fixture.morning.cards.count == 1)
        #expect(calls == 3)
    }

    @Test func generationWaitsForExistingWorkAndRetainsTheRequestedRun() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runID = try fixture.save("Review contract", at: Date())
        let other = try fixture.desktop.executor.begin(TaskRequest(id: UUID(), title: "Current job"))
        var calls = 0
        let service = fixture.service { _, _, messages, executor in
            calls += 1
            _ = await executor(CardGenerationSubmission.toolName, ["proposals": [Self.proposal(try Self.key(in: messages))]], nil)
            return "Ready"
        }
        let pending = try #require(service.generate(runID: runID))
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(calls == 0)
        #expect(service.isRunning)
        #expect(service.status.contains("Waiting"))
        other.finish(outcome: .completed, text: "Done", elapsed: 0)
        await pending.value
        #expect(calls == 1)
        #expect(fixture.morning.cards.count == 1)
    }

    @Test func proseOrUnrelatedIdentitiesCannotBecomeCards() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runID = try fixture.save("Review contract", at: Date())
        let service = fixture.service { _, _, _, executor in
            let rejected = await executor(CardGenerationSubmission.toolName,
                ["proposals": [Self.proposal("invented-item")]], nil)
            #expect(rejected.isError)
            #expect((rejected.content as? String)?.contains("unresolved observation") == true)   // turned down for its identity, not its shape
            return "I made a card about a completely unrelated thing."
        }
        await service.generate(runID: runID)?.value
        #expect(fixture.morning.cards.isEmpty)
        #expect((fixture.morning.workspace.cardGenerations ?? []).isEmpty)
        #expect(service.error?.contains("No structured") == true)
        #expect(fixture.desktop.tasks.history.first?.outcome == .failed)
    }

    @Test func latestSavedInputUsesSuccessfulEntriesAndSkipsRemovedSources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        _ = try fixture.save("Older details", at: now)
        let latest = try fixture.save("Latest details", at: now.addingTimeInterval(60))
        let input = CardGenerationInput.saved(in: fixture.sources, runID: nil, excluding: [])
        #expect(input.runIDs == [latest])
        #expect(input.observations.first?.excerpt.contains("Latest details") == true)
        #expect(CardGenerationInput.saved(in: fixture.sources, runID: nil, excluding: [latest]).runIDs.isEmpty)
        try fixture.sources.removeSource(id: fixture.source.id)
        #expect(CardGenerationInput.saved(in: fixture.sources, runID: latest, excluding: []).observations.isEmpty)
    }

    @Test func largeCollectionsReviewEveryBatchBeforeSavingOneReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<4 {
            var source = fixture.source
            if index > 0 { source.id = UUID(); source.name = "Inbox \(index)"; try fixture.sources.saveReadingSource(source) }
            let items = (0..<25).map { item in
                ReadingItem(id: "item-\(item)", title: "Review \(item)", text: "A review is waiting", evidence: "Visible row")
            }
            try fixture.sources.saveReadingSnapshot(ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
                items: items, coverage: .complete, accountEvidence: "Current account", sourceEvidence: "Inbox", scopeEvidence: "Recent rows"))
        }
        var batchSizes: [Int] = []
        let service = fixture.service { _, _, messages, executor in
            let keys = try Self.keys(in: messages)
            batchSizes.append(keys.count)
            #expect(fixture.morning.cards.isEmpty)
            #expect((fixture.morning.workspace.cardGenerations ?? []).isEmpty)
            let submitted = await executor(CardGenerationSubmission.toolName,
                ["proposals": keys.map { Self.proposal($0) }], nil)
            #expect(!submitted.isError)
            return "Batch reviewed"
        }
        await service.generate()?.value
        #expect(service.error == nil)
        #expect(batchSizes == [80, 20])
        #expect(fixture.morning.cards.count == 100)
        #expect(fixture.morning.workspace.cardGenerations?.count == 1)
        #expect(fixture.morning.workspace.cardGenerations?.first?.runIDs.count == 4)
    }

    private static func proposal(_ key: String, title: String = "Review contract") -> [String: Any] {
        ["observationKey": key, "title": title, "meaning": "A contract review is waiting on you.",
         "options": [["title": "Prepare review questions", "instruction": "Draft questions using the saved contract observation.", "mode": "prepare"]]]
    }

    private static func messageText(_ messages: [[String: Any]]) -> String {
        ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private static func key(in messages: [[String: Any]]) throws -> String {
        try #require(keys(in: messages).first)
    }

    private static func keys(in messages: [[String: Any]]) throws -> [String] {
        let text = messageText(messages)
        let split = try #require(text.range(of: "\n\n"))
        let data = Data(text[split.upperBound...].utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["observations"] as? [[String: Any]])
        return rows.compactMap { $0["observationKey"] as? String }
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("card-generation-\(UUID())")
        let source = LearnedReadingSource(kind: .mail, name: "Inbox", meaning: "Unread mail",
            url: "https://mail.example.test/inbox", scope: "Recent unread messages")
        let desktop = DesktopExecutionService(control: ComputerController(), activities: NativeActivityGate())
        let sources: CalendarStore
        let morning: MorningStore

        init() throws {
            sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
            morning = MorningStore(directory: root.appendingPathComponent("morning"))
            try sources.saveReadingSource(source)
        }

        func save(_ text: String, at: Date, state: ObservedItemState = .open) throws -> UUID {
            let item = ReadingItem(id: "changing-row-\(UUID())", title: "Contract review", text: text,
                evidence: "Visible message row: \(text)", url: "https://mail.example.test/thread/123",
                identityKey: "thread-123", identityEvidence: "Thread permalink 123",
                observedState: state, stateEvidence: text)
            let snapshot = ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
                collectedAt: at, items: [item], coverage: .complete, accountEvidence: "Current account",
                sourceEvidence: "Inbox", scopeEvidence: "Recent unread messages")
            try sources.saveReadingSnapshot(snapshot)
            return try #require(sources.runStore.runs.first { $0.entries.first?.readingSnapshot?.id == snapshot.id }?.id)
        }

        func service(_ body: @escaping Client.Body) -> CardGenerationService {
            CardGenerationService(morning: morning, sources: sources, desktop: desktop,
                config: { Config() }, makeClient: { _ in Client(body) })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Client: ConversationClient {
        typealias Body = @MainActor (String, [[String: Any]], [[String: Any]], @escaping ToolExecutor) async throws -> String
        var effort = "medium"
        var maxTokens = 8_192
        var maxToolRounds = 8
        var shouldStop: () -> Bool = { false }
        let body: Body
        init(_ body: @escaping Body) { self.body = body }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            let text = try await body(system, tools, messages, executor)
            messages.append(["role": "assistant", "content": [["type": "text", "text": text]]])
            return ClaudeReply(text: text, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 1)
        }
    }
}
