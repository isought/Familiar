import Foundation
import Testing
import FamiliarContracts
@testable import FamiliarRuntime

@Suite
@MainActor
struct ExecutionCoordinatorTests {
    @Test
    func successRunsTheBoundToolsRestoresClientSettingsAndCleansUpBeforeFinishing() async throws {
        let coordinator = ExecutionCoordinator()
        let statusSeen = Gate()
        var events: [String] = []
        var statuses: [String] = []
        var cleanupCount = 0
        coordinator.onUpdate = { update in events.append("phase:\(update.phase)") }
        let client = FakeClient { client, system, tools, messages, executor, onStatus in
            events.append("provider")
            #expect(system == "Fixture system")
            #expect(tools.first?["name"] as? String == "echo")
            #expect(messages.count == 1)
            #expect(client.maxToolRounds == 17)
            #expect(!client.shouldStop())
            let result = await executor("echo", ["value": "bound input"], nil)
            #expect(result.content as? String == "bound result")
            onStatus("Inspecting the fixture")
            try await statusSeen.wait()
            return response("Fixture answer")
        }
        client.maxToolRounds = 3
        client.shouldStop = { true }
        let route = ToolRoute(match: .tool(name: "echo"), definition: ["name": "echo"]) { name, input, toolset in
            #expect(name == "echo")
            #expect(input["value"] as? String == "bound input")
            #expect(toolset == nil)
            return .text("bound result")
        }
        let result = try await coordinator.run(client: client, content: [text("Question")], prepareImages: false, prepare: {
            events.append("prepare")
            return PreparedExecution(system: "Fixture system", router: try ToolRouter(routes: [route]), maxToolRounds: 17)
        }, cleanup: {
            cleanupCount += 1
            events.append("cleanup")
            #expect(coordinator.isRunning)
            #expect(coordinator.update?.phase != .finished)
            #expect(client.maxToolRounds == 3)
            #expect(client.shouldStop())
        }, onStatus: { status in
            statuses.append(status)
            statusSeen.open()
        })

        guard case .reply(let reply) = result.outcome else { Issue.record("Expected a reply"); return }
        #expect(reply.text == "Fixture answer")
        #expect(result.accepted)
        #expect(result.elapsed >= 0)
        #expect(cleanupCount == 1)
        #expect(Array(events.suffix(2)) == ["cleanup", "phase:finished"])
        #expect(statuses == ["Inspecting the fixture"])
        #expect(!coordinator.isRunning)
        #expect(!coordinator.conversation.isRunning)
        #expect(coordinator.update?.phase == .finished)
        #expect(coordinator.conversation.messages.count == 2)
    }

    @Test(arguments: [true, false])
    func preparationAndProviderFailuresCleanUpOnceAndDropOnlyTheFailedTurn(failPreparation: Bool) async throws {
        let session = ConversationSession()
        let savedTurn = try session.begin(content: [text("Previous question")], prepareImages: false)
        let saved = savedTurn.messages + [["role": "assistant", "content": [text("Previous answer")]]]
        session.complete(savedTurn, messages: saved)
        let coordinator = ExecutionCoordinator(conversation: session)
        var providerCalls = 0
        var events: [String] = []
        coordinator.onUpdate = { if $0.phase == .finished { events.append("finished") } }
        let client = FakeClient { _, _, _, _, _, _ in
            providerCalls += 1
            throw FixtureError.provider
        }
        let result = try await coordinator.run(client: client, content: [text("Failed question")], prepareImages: false, prepare: {
            if failPreparation { throw FixtureError.preparation }
            return try plan()
        }, cleanup: { events.append("cleanup") })

        guard case .failed(let error) = result.outcome else { Issue.record("Expected a failure"); return }
        #expect(error as? FixtureError == (failPreparation ? .preparation : .provider))
        #expect(result.accepted)
        #expect(providerCalls == (failPreparation ? 0 : 1))
        #expect(events == ["cleanup", "finished"])
        #expect(!coordinator.isRunning)
        #expect(!session.isRunning)
        #expect(NSArray(array: session.messages).isEqual(to: saved))
    }

    @Test(arguments: [false, true])
    func cancellationResolvesTheNativeGateAndCancelsTheProviderTask(cancelCaller: Bool) async throws {
        let coordinator = ExecutionCoordinator()
        let entered = Gate()
        let nativeGate = Gate()
        var nativeStops = 0
        var cleanups = 0
        var observedCancellation = false
        let client = FakeClient { client, _, _, _, _, _ in
            entered.open()
            try await nativeGate.wait()
            observedCancellation = Task.isCancelled && client.shouldStop()
            // Even an adapter returning after Stop must not publish a successful reply.
            return response("Too late")
        }
        let task = Task { @MainActor in
            try await coordinator.run(client: client, content: [text("Question")], prepare: { try plan() }, stopNative: {
                nativeStops += 1
                nativeGate.open()
            }, cleanup: { cleanups += 1 })
        }
        try await entered.wait()
        if cancelCaller { task.cancel() } else { coordinator.cancel(); coordinator.cancel() }
        let result = try await task.value

        guard case .cancelled = result.outcome else { Issue.record("Expected cancellation"); return }
        #expect(result.accepted)
        #expect(nativeStops == 1)
        #expect(cleanups == 1)
        #expect(observedCancellation)
        #expect(!coordinator.isRunning)
        #expect(coordinator.conversation.messages.count == 2)
        #expect(try stoppedText(coordinator.conversation).contains("No tools were attempted."))
        #expect(coordinator.update?.phase == .finished)
    }

    enum EarlyCancellation: CaseIterable { case cancelledCaller, preparingSubscriber, runningSubscriber }

    @Test(arguments: EarlyCancellation.allCases)
    func earlyCancellationDoesNotEnterTheProvider(point: EarlyCancellation) async throws {
        let coordinator = ExecutionCoordinator()
        var providerCalls = 0
        var nativeStops = 0
        var cleanups = 0
        coordinator.onUpdate = { update in
            if (point == .preparingSubscriber && update.phase == .preparing) ||
                (point == .runningSubscriber && update.phase == .running) {
                coordinator.cancel()
            }
        }
        let client = FakeClient { _, _, _, _, _, _ in
            providerCalls += 1
            return response("Must not run")
        }
        let task = Task { @MainActor in
            if point == .cancelledCaller { withUnsafeCurrentTask { $0?.cancel() } }
            return try await coordinator.run(client: client, content: [text("Question")], prepare: { try plan() },
                                             stopNative: { nativeStops += 1 }, cleanup: { cleanups += 1 })
        }
        let result = try await task.value

        guard case .cancelled = result.outcome else { Issue.record("Expected cancellation"); return }
        #expect(result.accepted)
        #expect(providerCalls == 0)
        #expect(nativeStops == 1)
        #expect(cleanups == 1)
        #expect(!coordinator.isRunning)
        #expect(coordinator.conversation.messages.count == 2)
        #expect(try stoppedText(coordinator.conversation).contains("No tools were attempted."))
    }

    @Test
    func clearSuppressesLateProviderStatusAndReplyWithoutReleasingActiveWork() async throws {
        let coordinator = ExecutionCoordinator()
        let entered = Gate()
        let release = Gate()
        let firstStatus = Gate()
        var statuses: [String] = []
        var cleanups = 0
        let client = FakeClient { _, _, _, _, _, onStatus in
            onStatus("Current status")
            try await firstStatus.wait()
            entered.open()
            try await release.wait()
            onStatus("Stale status")
            await Task.yield()
            return response("Stale reply")
        }
        let task = Task { @MainActor in
            try await coordinator.run(client: client, content: [text("Question")], prepare: { try plan() }, cleanup: { cleanups += 1 }, onStatus: {
                statuses.append($0)
                firstStatus.open()
            })
        }
        try await entered.wait()
        coordinator.conversation.clear()
        #expect(coordinator.isRunning)
        #expect(coordinator.conversation.isRunning)
        release.open()
        let result = try await task.value

        guard case .reply = result.outcome else { Issue.record("Expected a completed but invalidated provider reply"); return }
        #expect(!result.accepted)
        #expect(statuses == ["Current status"])
        #expect(coordinator.conversation.messages.isEmpty)
        #expect(!coordinator.isRunning)
        #expect(!coordinator.conversation.isRunning)
        #expect(cleanups == 1)
    }

    @Test
    func clearDuringPreparationSuppressesTheDelayedRunningStatus() async throws {
        let coordinator = ExecutionCoordinator()
        let preparing = Gate()
        let release = Gate()
        var phases: [ExecutionUpdate.Phase] = []
        var statuses: [String] = []
        coordinator.onUpdate = { phases.append($0.phase) }
        let client = FakeClient { _, _, _, _, _, onStatus in
            onStatus("Stale provider status")
            await Task.yield()
            return response("Stale answer")
        }
        let task = Task { @MainActor in
            try await coordinator.run(client: client, content: [text("Question")], prepare: {
                preparing.open()
                try await release.wait()
                return try plan()
            }, onStatus: { statuses.append($0) })
        }
        try await preparing.wait()
        coordinator.conversation.clear()
        release.open()
        let result = try await task.value
        #expect(!result.accepted)
        #expect(phases == [.preparing, .finished])
        #expect(statuses.isEmpty)
        #expect(coordinator.conversation.messages.isEmpty)
    }

    @Test
    func duplicateAdmissionCannotPrepareOrMutateAnActiveRun() async throws {
        let coordinator = ExecutionCoordinator()
        let entered = Gate()
        let release = Gate()
        var admittedCleanups = 0
        var rejectedPreparations = 0
        var rejectedCleanups = 0
        let client = FakeClient { _, _, _, _, _, _ in
            entered.open()
            try await release.wait()
            return response("First answer")
        }
        let first = Task { @MainActor in
            try await coordinator.run(client: client, content: [text("First question")], prepare: { try plan() }, cleanup: { admittedCleanups += 1 })
        }
        try await entered.wait()
        let snapshot = coordinator.conversation.messages
        do {
            _ = try await coordinator.run(client: client, content: [text("Rejected question")], prepare: {
                rejectedPreparations += 1
                return try plan()
            }, cleanup: { rejectedCleanups += 1 })
            Issue.record("Expected duplicate admission to fail")
        } catch let error as ConversationSessionError {
            #expect(error == .turnAlreadyRunning)
        }
        #expect(rejectedPreparations == 0)
        #expect(rejectedCleanups == 0)
        #expect(NSArray(array: coordinator.conversation.messages).isEqual(to: snapshot))
        #expect(coordinator.isRunning)
        release.open()
        let result = try await first.value
        #expect(result.accepted)
        #expect(admittedCleanups == 1)
    }

    @Test
    func independentCoordinatorsKeepTheirCancellationAndHistorySeparate() async throws {
        let first = ExecutionCoordinator()
        let second = ExecutionCoordinator()
        let firstEntered = Gate(), secondEntered = Gate()
        let firstRelease = Gate(), secondRelease = Gate()
        let firstClient = FakeClient { _, _, _, _, _, _ in
            firstEntered.open()
            try await firstRelease.wait()
            return response("Cancelled first answer")
        }
        let secondClient = FakeClient { _, _, _, _, _, _ in
            secondEntered.open()
            try await secondRelease.wait()
            return response("Independent second answer")
        }
        let firstTask = Task { @MainActor in
            try await first.run(client: firstClient, content: [text("First question")], prepare: { try plan() }, stopNative: { firstRelease.open() })
        }
        let secondTask = Task { @MainActor in
            try await second.run(client: secondClient, content: [text("Second question")], prepare: { try plan() })
        }
        try await firstEntered.wait()
        try await secondEntered.wait()
        first.cancel()
        let firstResult = try await firstTask.value
        guard case .cancelled = firstResult.outcome else { Issue.record("Expected first cancellation"); return }
        #expect(first.conversation.messages.count == 2)
        #expect(try stoppedText(first.conversation).contains("No tools were attempted."))
        #expect(second.isRunning)
        #expect(second.conversation.isRunning)
        secondRelease.open()
        let secondResult = try await secondTask.value
        guard case .reply(let reply) = secondResult.outcome else { Issue.record("Expected the independent reply"); return }
        #expect(reply.text == "Independent second answer")
        #expect(secondResult.accepted)
        #expect(second.conversation.messages.count == 2)
        #expect(!second.isRunning)
    }

    @Test
    func forcedCancellationRetainsCompletedToolContextWithoutPartialProviderHistory() async throws {
        let coordinator = ExecutionCoordinator()
        let awaitingProvider = Gate()
        let imageData = "IMAGE-DATA-MUST-NOT-ENTER-TEXT-SUMMARY"
        let routes = [
            ToolRoute(match: .tool(name: "notes__update"), definition: ["name": "notes__update"]) { _, _, _ in
                .blocks([["type": "text", "text": "Saved revision 7."],
                         ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": imageData]]])
            },
            ToolRoute(match: .tool(name: "inspect", toolset: "documents"), definition: ["name": "inspect"]) { _, _, _ in
                .text("Permission denied.", isError: true)
            },
        ]
        let client = FakeClient { _, _, _, _, executor, _ in
            _ = await executor("notes__update", ["note_id": "42", "title": "Updated title"], nil)
            _ = await executor("inspect", ["document_id": 9], "documents")
            awaitingProvider.open()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return response("Not reached")
        }
        client.historyBeforeBehavior = [["role": "assistant", "content": [
            ["type": "thinking", "thinking": "Provider-specific reasoning", "signature": "incomplete-provider-signature"],
            ["type": "tool_use", "id": "unmatched-use", "name": "notes__update", "input": [:]],
        ]]]
        let task = Task { @MainActor in
            try await coordinator.run(client: client, content: [text("Update note 42 and inspect document 9")], prepareImages: false,
                                      prepare: { PreparedExecution(system: "Fixture system", router: try ToolRouter(routes: routes)) })
        }
        try await awaitingProvider.wait()
        coordinator.cancel()
        let result = try await task.value
        guard case .cancelled = result.outcome else { Issue.record("Expected cancellation"); return }
        #expect(result.accepted)
        let summary = try stoppedText(coordinator.conversation)
        #expect(summary.contains("notes__update"))
        #expect(summary.contains("\"note_id\":\"42\""))
        #expect(summary.contains("Saved revision 7."))
        #expect(summary.contains("Image returned"))
        #expect(!summary.contains(imageData))
        #expect(summary.contains("documents.inspect"))
        #expect(summary.contains("Returned error: Permission denied."))
        #expect(!summary.contains("Outcome unknown"))
        let historyJSON = String(decoding: try JSONSerialization.data(withJSONObject: coordinator.conversation.messages), as: UTF8.self)
        #expect(!historyJSON.contains("incomplete-provider-signature"))
        #expect(!historyJSON.contains("unmatched-use"))
        let next = try coordinator.conversation.begin(content: [text("Continue from there")], prepareImages: false)
        #expect(next.messages.count == 3)
        let remembered = try #require(next.messages[1]["content"] as? [[String: Any]])
        #expect(remembered.first?["text"] as? String == summary)
        coordinator.conversation.fail(next)
    }

    @Test
    func forcedCancellationMarksAnInflightToolUnknownAndLateReturnDoesNotRewriteHistory() async throws {
        let coordinator = ExecutionCoordinator()
        let toolEntered = Gate(), releaseTool = Gate()
        var invocation: Task<ToolResult, Never>?
        let route = ToolRoute(match: .tool(name: "save_record"), definition: ["name": "save_record"]) { _, _, _ in
            await toolEntered.open()
            do { try await releaseTool.wait() } catch { return .text("Fixture gate timed out", isError: true) }
            return .text("Eventually saved.")
        }
        let client = FakeClient { _, _, _, _, executor, _ in
            // Simulates an adapter with an outstanding tool call when its provider wait is cancelled.
            invocation = Task { await executor("save_record", ["record_id": "record-5"], nil) }
            try await toolEntered.wait()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return response("Not reached")
        }
        let task = Task { @MainActor in
            try await coordinator.run(client: client, content: [text("Save record 5")], prepareImages: false,
                                      prepare: { PreparedExecution(system: "Fixture system", router: try ToolRouter(routes: [route])) })
        }
        try await toolEntered.wait()
        coordinator.cancel()
        let result = try await task.value
        guard case .cancelled = result.outcome else { releaseTool.open(); Issue.record("Expected cancellation"); return }
        #expect(result.accepted)
        let summary = try stoppedText(coordinator.conversation)
        #expect(summary.contains("save_record"))
        #expect(summary.contains("record-5"))
        #expect(summary.contains("Outcome unknown"))
        #expect(summary.contains("Check the current state before retrying"))
        releaseTool.open()
        _ = await invocation?.value
        #expect(try stoppedText(coordinator.conversation) == summary)
        #expect(!summary.contains("Eventually saved."))
    }

    @Test(arguments: [false, true])
    func invalidationRejectsTheForcedCancellationSummary(changeProvider: Bool) async throws {
        let coordinator = ExecutionCoordinator()
        let entered = Gate()
        let client = FakeClient { _, _, _, _, _, _ in
            entered.open()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return response("Not reached")
        }
        let task = Task { @MainActor in
            try await coordinator.run(client: client, content: [text("Question")], prepareImages: false, prepare: { try plan() })
        }
        try await entered.wait()
        if changeProvider { coordinator.conversation.retainTextForProviderChange() } else { coordinator.conversation.clear() }
        let snapshot = coordinator.conversation.messages
        coordinator.cancel()
        let result = try await task.value
        guard case .cancelled = result.outcome else { Issue.record("Expected cancellation"); return }
        #expect(!result.accepted)
        #expect(NSArray(array: coordinator.conversation.messages).isEqual(to: snapshot))
        #expect(!coordinator.isRunning)
        #expect(!coordinator.conversation.isRunning)
    }

    private func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
    private func stoppedText(_ session: ConversationSession) throws -> String {
        let content = try #require(session.messages.last?["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }
    private func plan() throws -> PreparedExecution { PreparedExecution(system: "Fixture system", router: try ToolRouter(routes: [])) }
    private func response(_ value: String) -> FakeClient.Response {
        FakeClient.Response(reply: ClaudeReply(text: value, inputTokens: 1, outputTokens: 2, cacheRead: 0, toolCalls: 0),
                            appended: [["role": "assistant", "content": [text(value)]]])
    }

    private enum FixtureError: Error, Equatable { case preparation, provider, gateTimedOut }

    /// A deliberately non-cancelling native-style continuation. Stop must resolve it.
    @MainActor
    private final class Gate {
        private var opened = false
        private var waiters: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]

        func wait() async throws {
            if opened { return }
            let id = UUID()
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    self?.waiters.removeValue(forKey: id)?.0.resume(throwing: FixtureError.gateTimedOut)
                }
                waiters[id] = (continuation, timeout)
            }
        }

        func open() {
            opened = true
            let pending = waiters.values
            waiters.removeAll()
            for (continuation, timeout) in pending {
                timeout.cancel()
                continuation.resume()
            }
        }
    }

    private final class FakeClient: ConversationClient {
        struct Response {
            let reply: ClaudeReply
            let appended: [[String: Any]]
        }

        typealias Behavior = @MainActor (FakeClient, String, [[String: Any]], [[String: Any]], @escaping ToolExecutor, (String) -> Void) async throws -> Response
        var effort = "medium"
        var maxTokens = 1024
        var maxToolRounds = 8
        var shouldStop: () -> Bool = { false }
        var historyBeforeBehavior: [[String: Any]] = []
        private let behavior: Behavior

        init(_ behavior: @escaping Behavior) { self.behavior = behavior }

        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            messages += historyBeforeBehavior
            let result = try await behavior(self, system, tools, messages, executor, onStatus)
            messages += result.appended
            return result.reply
        }
    }
}
