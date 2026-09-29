import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct TaskExecutorTests {
    @Test func producerCommitsItsResultBeforeJobCompletion() async throws {
        let fixture = Fixture()
        let id = UUID()
        var oldStops = 0
        fixture.desktop.peek.onStop = { oldStops += 1 }
        let job = try fixture.desktop.executor.begin(TaskRequest(id: id, title: "Prepare a result"))
        #expect(fixture.desktop.tasks.activeTask?.id == id)
        let client = Client { "Observed result" }
        let result = try await job.run(TaskPlan(content: [["type": "text", "text": "Collect this scope"]], prepare: {
            PreparedExecution(system: "Producer instructions", router: try ToolRouter(routes: []))
        }), client: client)
        // Returning from the provider has not yet claimed successful collection.
        #expect(fixture.desktop.tasks.history.isEmpty)
        #expect(fixture.desktop.tasks.activeTask?.id == id)
        var saved: String?
        if case .reply(let reply) = result.outcome { saved = reply.text }
        #expect(saved == "Observed result")
        job.finish(outcome: .completed, text: try #require(saved), elapsed: result.elapsed)
        #expect(fixture.desktop.tasks.history.first?.text == saved)
        #expect(fixture.desktop.tasks.activeTask == nil)
        fixture.desktop.peek.onStop?()
        #expect(oldStops == 1)
    }

    @Test func conversationPromotesOnlyWhenAnActionStarts() async throws {
        let fixture = Fixture()
        var promotions = 0
        let question = try fixture.desktop.executor.begin(TaskRequest(id: UUID(), title: "What is visible?", presentation: .conversation),
            onPromoted: { promotions += 1 })
        let questionResult = try await question.run(fixture.desktopPlan(question.request.id), client: Client {
            fixture.desktop.executor.nativeDidBegin()
            #expect(fixture.desktop.tasks.activeTask == nil)
            return "An answer in chat"
        })
        question.finish(outcome: .completed, text: "An answer in chat", elapsed: questionResult.elapsed)
        #expect(fixture.desktop.tasks.history.isEmpty)
        #expect(promotions == 0)

        let action = try fixture.desktop.executor.begin(TaskRequest(id: UUID(), title: "Do the requested task", presentation: .conversation),
            onPromoted: { promotions += 1 })
        let actionResult = try await action.run(fixture.desktopPlan(action.request.id), client: Client {
            fixture.desktop.executor.backgroundDidBegin()
            fixture.desktop.executor.backgroundDidBegin()
            #expect(action.isPresented)
            return "Action result"
        })
        action.finish(outcome: .completed, text: "Action result", elapsed: actionResult.elapsed)
        #expect(promotions == 1)
        #expect(fixture.desktop.tasks.history.map(\.id) == [action.request.id])
        #expect(!fixture.desktop.isBusy)
    }

    @Test func taskReservationAndStopBelongToExecutor() async throws {
        let fixture = Fixture()
        var stops = 0
        let job = try fixture.desktop.executor.begin(TaskRequest(id: UUID(), title: "Any producer"), onStop: { stops += 1 })
        #expect(throws: (any Error).self) {
            try fixture.desktop.executor.begin(TaskRequest(id: UUID(), title: "Conflicting job"))
        }
        let result = try await job.run(TaskPlan(content: [["type": "text", "text": "Work"]], prepare: {
            PreparedExecution(system: "Task", router: try ToolRouter(routes: []))
        }), client: Client {
            // Native startup replaces this callback; the executor reconnects it.
            fixture.desktop.peek.onStop = {}
            fixture.desktop.executor.nativeDidBegin()
            fixture.desktop.peek.onStop?()
            try Task.checkCancellation()
            return "Should not complete"
        })
        #expect(stops == 1)
        if case .cancelled = result.outcome {} else { Issue.record("Stop must cancel the whole provider turn") }
        job.finish(outcome: .stopped, text: "Stopped", elapsed: result.elapsed)
        #expect(fixture.desktop.tasks.history.first?.outcome == .stopped)
        let next = try fixture.desktop.executor.begin(TaskRequest(id: UUID(), title: "Next producer"))
        next.finish(outcome: .completed, text: "Ready", elapsed: 0)
    }

    @Test func executorReleasesNativeOwnershipAfterPreparationFailure() async throws {
        let fixture = Fixture()
        let job = try fixture.desktop.executor.begin(TaskRequest(id: UUID(), title: "Read source"))
        let result = try await job.run(TaskPlan(content: [["type": "text", "text": "Read"]], prepare: {
            _ = try await fixture.desktopPlan(job.request.id).prepare()
            throw ClaudeError(message: "Preparation failed")
        }), client: Client { Issue.record("Provider must not run"); return "" })
        if case .failed = result.outcome {} else { Issue.record("Expected preparation failure") }
        #expect(!fixture.desktop.isBusy)
        #expect(fixture.activities.current == nil)
        job.finish(outcome: .failed, text: "Preparation failed", elapsed: result.elapsed)
        #expect(fixture.desktop.tasks.history.first?.outcome == .failed)
    }

    @MainActor private final class Fixture {
        let activities = NativeActivityGate()
        lazy var desktop = DesktopExecutionService(control: ComputerController(), activities: activities, enablesPeek: false)
        let registry = ToolRegistry(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                    runner: ScriptRunner(config: Config()))

        func desktopPlan(_ id: UUID) -> TaskPlan {
            TaskPlan(content: [["type": "text", "text": "Execute the supplied task"]], prepare: {
                try await self.desktop.prepare(id: id, registry: self.registry, context: nil, background: true,
                    resolveFrontmost: false, lookAtScreen: { .text("Fixture") })
            })
        }
    }

    private final class Client: ConversationClient {
        var effort = "medium"
        var maxTokens = 1024
        var maxToolRounds = 8
        var shouldStop: () -> Bool = { false }
        let body: @MainActor () async throws -> String
        init(_ body: @escaping @MainActor () async throws -> String) { self.body = body }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            let text = try await body()
            messages.append(["role": "assistant", "content": [["type": "text", "text": text]]])
            return ClaudeReply(text: text, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 0)
        }
    }
}
