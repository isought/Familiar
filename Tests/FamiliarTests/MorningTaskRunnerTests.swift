import Combine
import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct MorningTaskRunnerTests {
    @Test func savedQueueArrivalIsPassiveAndResultsRemainSelectableAfterRestart() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        let card = MorningCard(folderID: UUID(), title: "Review",
                               action: MorningAction(title: "Prepare review", instruction: "Draft the review"))
        var item = MorningWorkItem(cardID: card.id, card: card, people: [], action: card.action)
        var opens = 0
        let observation = store.explicitOpenRequests.sink { opens += 1 }
        defer { observation.cancel() }
        store.syncMorning([item], message: "Waiting for a connection")
        #expect(store.hasTasks)
        #expect(store.queuedCount == 1)
        #expect(store.isVisible)
        #expect(!store.isExpanded)
        #expect(opens == 0)
        store.dismiss()
        store.syncMorning([item], message: "Still waiting")
        #expect(!store.isVisible)
        item.status = .completed
        item.result = "Saved review"
        store.syncMorning([item], message: nil)
        store.selectTask(id: item.id)
        #expect(store.selectedMorningWork?.result == "Saved review")
        #expect(store.queuedCount == 0)
        #expect(store.isExpanded)
        #expect(opens == 1)
        store.dismiss()
        let next = MorningWorkItem(cardID: card.id, card: card, people: [], action: card.action)
        store.syncMorning([item, next], message: nil)
        #expect(store.isVisible)
        #expect(!store.isExpanded)
        #expect(opens == 1)
    }

    @Test func serialPreparationUsesAcceptedEvidenceAndNoTools() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let person = MorningPerson(name: "Maya", relationship: "Launch owner", context: "Waiting for the original review")
        try fixture.store.savePerson(person)
        var first = fixture.card("First")
        first.personIDs = [person.id]
        first.sources = [MorningSource(title: "Original email", excerpt: "Original evidence")]
        try fixture.store.saveCard(first)
        let one = try fixture.store.enqueue(cardID: first.id)
        let second = fixture.card("Second")
        try fixture.store.saveCard(second)
        let two = try fixture.store.enqueue(cardID: second.id)
        first.sources[0].excerpt = "Edited after acceptance"
        try fixture.store.saveCard(first)
        var changedPerson = person
        changedPerson.context = "New relationship context"
        try fixture.store.savePerson(changedPerson)
        var calls: [String] = []
        var clients = 0
        var oldStops = 0
        fixture.desktop.peek.onStop = { oldStops += 1 }
        let runner = fixture.runner { _ in
            clients += 1
            return FakeClient { system, tools, messages, executor in
                #expect(tools.isEmpty)
                #expect(system.contains("no tools"))
                #expect(messages.count == 1)
                let text = Self.messageText(messages)
                if calls.isEmpty {
                    #expect(text.contains("Original evidence"))
                    #expect(text.contains("Waiting for the original review"))
                    #expect(!text.contains("Edited after acceptance"))
                    #expect(!text.contains("New relationship context"))
                    #expect(fixture.store.workItems[0].status == .running)
                    #expect(fixture.store.workItems[1].status == .queued)
                    calls.append("First")
                    try await Task.sleep(nanoseconds: 20_000_000)
                } else {
                    #expect(fixture.store.workItems[0].status == .completed)
                    calls.append("Second")
                }
                let blocked = await executor("computer__key", ["text": "Return"], nil)
                #expect(blocked.isError)
                return "Prepared \(calls.last!)"
            }
        }
        runner.start()
        runner.wake()
        runner.wake()
        try await until { fixture.store.workItems.allSatisfy { $0.status == .completed } }
        #expect(calls == ["First", "Second"])
        #expect(clients == 2)
        #expect(fixture.desktop.tasks.history.map(\.id) == [two.id, one.id])
        #expect(fixture.store.workItems.map(\.result) == ["Prepared First", "Prepared Second"])
        fixture.desktop.peek.onStop?()
        #expect(oldStops == 1)
        #expect(!fixture.desktop.isBusy)
        #expect(!runner.isRunning)
        runner.shutdown()
    }

    @Test func waitsForNativeOwnerWithoutConsumingProviderThenContinues() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.enqueue("Waiting")
        let lease = try fixture.activities.acquire(.recording)
        var factories = 0
        var pauses = 0
        let runner = fixture.runner(pause: {
            pauses += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }) { _ in
            factories += 1
            return FakeClient { _, _, _, _ in "Ready" }
        }
        runner.start()
        try await until { pauses >= 2 }
        #expect(factories == 0)
        #expect(fixture.store.workItems.first?.status == .queued)
        #expect(fixture.desktop.tasks.queuedCount == 1)
        fixture.activities.release(lease)
        try await until { fixture.store.workItems.first?.status == .completed }
        #expect(factories == 1)
        runner.shutdown()
    }

    @Test func missingProviderPausesUntilExplicitWakeAndDesktopGateDoesNotConsumeIt() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.enqueue("Prepare")
        var connected = false
        var factories = 0
        let runner = fixture.runner { _ in
            factories += 1
            return connected ? FakeClient { _, _, _, _ in "Ready" } : nil
        }
        runner.start()
        try await until { fixture.store.queueMessage != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(factories == 1)
        #expect(fixture.store.workItems.first?.status == .queued)
        connected = true
        runner.wake()
        try await until { fixture.store.workItems.first?.status == .completed }
        #expect(factories == 2)
        runner.shutdown()

        _ = try fixture.enqueue("Desktop", mode: .desktop)
        var blockedFactories = 0
        let disabled = fixture.runner { _ in
            blockedFactories += 1
            return FakeClient { _, _, _, _ in "Should not run" }
        }
        disabled.start()
        try await until { fixture.store.queueMessage?.contains("computer control") == true }
        #expect(blockedFactories == 0)
        #expect(fixture.store.workItems.last?.status == .queued)
        disabled.shutdown()
    }

    @Test func failedDurableStartPreventsExecutionAndDoesNotDiscardQueue() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.enqueue("Cannot save")
        try fixture.blockWrites()
        var calls = 0
        let runner = fixture.runner { _ in FakeClient { _, _, _, _ in calls += 1; return "Forbidden" } }
        runner.start()
        try await until { fixture.store.queueMessage?.contains("could not be saved") == true }
        #expect(calls == 0)
        #expect(fixture.store.workItems.first?.status == .queued)
        #expect(fixture.desktop.tasks.history.isEmpty)
        runner.shutdown()
    }

    @Test func approvalStateIsDurableAndStopCancelsTheWholeTurn() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let item = try fixture.enqueue("Approval")
        let runner = fixture.runner { _ in FakeClient { _, _, _, _ in
            fixture.desktop.peek.phase = .confirming("Review this action")
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "Too late"
        } }
        runner.start()
        try await until { fixture.store.workItems.first?.status == .needsAttention }
        #expect(fixture.desktop.tasks.activeTask?.id == item.id)
        fixture.desktop.executor.backgroundDidBegin()
        fixture.desktop.peek.onStop?()
        try await until { fixture.store.workItems.first?.status == .cancelled }
        #expect(fixture.desktop.tasks.history.first?.outcome == .stopped)
        #expect(fixture.store.cards.first?.disposition == .unreviewed)
        #expect(fixture.desktop.peek.onGoAhead == nil)
        #expect(!runner.isRunning)
        runner.shutdown()
    }

    @Test func unsavedResultIsNeverPresentedAsSuccessOrFollowedByAnotherTask() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.enqueue("First")
        _ = try fixture.enqueue("Second")
        var calls = 0
        let runner = fixture.runner { _ in FakeClient { _, _, _, _ in
            calls += 1
            try fixture.blockWrites()
            return "A useful result that could not be saved"
        } }
        runner.start()
        try await until { fixture.desktop.tasks.history.first != nil }
        #expect(calls == 1)
        #expect(fixture.store.workItems.map(\.status) == [.running, .queued])
        #expect(fixture.desktop.tasks.history.first?.outcome == .failed)
        #expect(fixture.desktop.tasks.history.first?.text.contains("could not be saved") == true)
        #expect(fixture.store.queueMessage != nil)
        runner.wake()
        runner.wake()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(calls == 1)
        #expect(fixture.store.workItems.map(\.status) == [.running, .queued])
        #expect(fixture.store.queueMessage?.contains("Restart Noteling") == true)
        runner.shutdown()
    }

    @Test func shutdownMarksInterruptedBeforeReturningAndDoesNotRunTheNextItem() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.enqueue("First")
        _ = try fixture.enqueue("Second")
        var calls = 0
        let runner = fixture.runner { _ in FakeClient { _, _, _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "Too late"
        } }
        runner.start()
        try await until { calls == 1 }
        runner.shutdown()
        #expect(fixture.store.workItems.map(\.status) == [.interrupted, .queued])
        try await until { !runner.isRunning }
        #expect(calls == 1)
        #expect(fixture.store.workItems.map(\.status) == [.interrupted, .queued])
    }

    @Test func desktopQueueHasNoImplicitForegroundTargetAndSamplesStayToolFree() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.enqueue("Explicit app task", mode: .desktop)
        var configuration = Config()
        configuration.allowControl = true
        let runner = fixture.runner(config: { configuration }) { _ in FakeClient { system, tools, _, executor in
            #expect(fixture.desktop.control.target == nil)
            #expect(system.contains("No target is selected"))
            #expect(tools.contains { $0["name"] as? String == "target_window" })
            let missing = await executor("look_at_screen", [:], nil)
            #expect(missing.isError)
            #expect((missing.content as? String)?.contains("No target") == true)
            return "Need the intended app"
        } }
        runner.start()
        try await until { fixture.store.workItems.first?.status == .completed }
        #expect(fixture.activities.current == nil)
        #expect(!fixture.desktop.isBusy)
        runner.shutdown()
        var sample = fixture.card("Sample")
        sample.isSample = true
        sample.action.mode = .desktop
        let malformed = MorningWorkItem(cardID: sample.id, card: sample, people: [], action: sample.action)
        #expect(MorningTaskRunner.mode(for: malformed) == .prepare)
    }

    private func until(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(condition(), "Timed out waiting for the isolated queue")
    }

    private static func messageText(_ messages: [[String: Any]]) -> String {
        ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("morning-runner-\(UUID().uuidString)")
        let activities = NativeActivityGate()
        lazy var store = MorningStore(directory: directory)
        lazy var desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
        lazy var registry = ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: Config()))

        func card(_ title: String, mode: MorningActionMode = .prepare) -> MorningCard {
            MorningCard(folderID: store.folders[0].id, title: title,
                        action: MorningAction(title: "Prepare \(title)", instruction: "Summarize \(title)", mode: mode))
        }
        func enqueue(_ title: String, mode: MorningActionMode = .prepare) throws -> MorningWorkItem {
            let file = card(title, mode: mode)
            try store.saveCard(file)
            return try store.enqueue(cardID: file.id)
        }
        func runner(config: @escaping () -> Config = { Config() },
                    pause: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000) },
                    make: @escaping (Config) -> (any ConversationClient)?) -> MorningTaskRunner {
            MorningTaskRunner(store: store, desktop: desktop, registry: registry, activities: activities,
                              config: config, makeClient: make, pause: pause)
        }
        func blockWrites() throws {
            let file = directory.appendingPathComponent("morning.sqlite")
            try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("saved.sqlite"))
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class FakeClient: ConversationClient {
        var effort = "medium"
        var maxTokens = 1024
        var maxToolRounds = 8
        var shouldStop: () -> Bool = { false }
        let body: @MainActor (String, [[String: Any]], [[String: Any]], @escaping ToolExecutor) async throws -> String
        init(_ body: @escaping @MainActor (String, [[String: Any]], [[String: Any]], @escaping ToolExecutor) async throws -> String) { self.body = body }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            let text = try await body(system, tools, messages, executor)
            messages.append(["role": "assistant", "content": [["type": "text", "text": text]]])
            return ClaudeReply(text: text, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 0)
        }
    }
}
