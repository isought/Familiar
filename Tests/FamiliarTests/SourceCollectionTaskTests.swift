import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct SourceCollectionTaskTests {
    @Test func ingestionPlanRunsThroughGenericExecutorWithoutSourceStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collection-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LearnedReadingSource(kind: .mail, name: "Work inbox", meaning: "Incoming work mail",
            application: "Google Chrome", url: "https://mail.example.test/inbox", account: "alex@example.test",
            scope: "Only unread mail from the last two days")
        let request = ReadingReadRequest(source: source)
        let collection = SourceCollectionTask.reading(request)
        #expect(collection.policy == .sourceRead)
        let evidence = CalendarCollectionEvidence()
        let desktop = DesktopExecutionService(control: ComputerController(), activities: NativeActivityGate())
        let registry = ToolRegistry(root: directory, runner: ScriptRunner(config: Config()))
        let plan = collection.plan(desktop: desktop, registry: registry, evidence: evidence,
            prepareExecution: { id, submissionRoutes, evidence in
                #expect(id == request.id)
                let read = ToolRoute(match: .tool(name: "read_screen"), definition: ["name": "read_screen"]) { _, _, _ in
                    evidence.observed()
                    return .text("Unread message received today: Project agenda")
                }
                return PreparedExecution(system: "unused", router: try ToolRouter(routes: submissionRoutes + [read]))
            }, validatePermission: {})
        let execution = try desktop.executor.begin(collection.executionRequest)
        #expect(desktop.tasks.activeTask?.id == request.id)
        let client = FakeClient { system, tools, messages, executor in
            #expect(system.contains("collecting fresh observations"))
            let text = ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            #expect(text.contains(source.scope))
            #expect(text.contains(request.id.uuidString))
            #expect(tools.contains { ($0["name"] as? String) == "submit_reading_collection" })
            _ = await executor("read_screen", [:], nil)
            let submission = await executor("submit_reading_collection", [
                "sourceID": source.id.uuidString, "requestID": request.id.uuidString,
                "coverage": "complete", "coverageNotes": ["All matching rows checked"],
                "accountEvidence": "Account menu shows alex@example.test",
                "sourceEvidence": "Address bar shows https://mail.example.test/inbox",
                "scopeEvidence": "Unread filter and dates checked through first row older than two days",
                "items": [["title": "Project agenda", "text": "Unread message received today",
                           "evidence": "Fresh inbox row"]]
            ], nil)
            #expect(!submission.isError)
            return "Collected"
        }
        let result = try await execution.run(plan, client: client)
        guard case .reply = result.outcome else { Issue.record("Expected a successful execution"); return }
        #expect(evidence.readingSnapshot?.items.map(\.title) == ["Project agenda"])
        // A provider reply only stages data. The ingestion owner decides when its
        // validated result has been saved and the generic task can be completed.
        #expect(desktop.tasks.history.isEmpty)
        #expect(desktop.tasks.activeTask?.id == request.id)
        execution.finish(outcome: .completed, text: try #require(collection.result(evidence)).text, elapsed: result.elapsed)
        #expect(desktop.tasks.activeTask == nil)
        #expect(desktop.tasks.history.first?.outcome == .completed)
    }

    @Test func trackedPlanKeepsDiscoveryScopeAndCapturesAtMostTenFollowUps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LearnedReadingSource(kind: .mail, name: "Work", meaning: "Work requests",
            url: "https://mail.example.test/inbox", scope: "Only unread mail from the last two days")
        let collection = SourceCollectionTask.reading(ReadingReadRequest(source: source))
        let tracked = (1...11).map { TrackedSourceItem(key: "thread:tracking-\($0)", title: "Tracked subject \($0)", details: "Awaiting reply", url: "", identityEvidence: "Original sender and subject") }
        let desktop = DesktopExecutionService(control: ComputerController(), activities: NativeActivityGate())
        let registry = ToolRegistry(root: directory, runner: ScriptRunner(config: Config()))
        let plan = collection.plan(desktop: desktop, registry: registry, evidence: CalendarCollectionEvidence(),
            prepareExecution: { _, routes, _ in PreparedExecution(system: "Unused", router: try ToolRouter(routes: routes)) },
            trackedItems: tracked, validatePermission: {})
        let prompt = try #require(plan.content.first?["text"] as? String)
        #expect(prompt.contains(source.scope))
        #expect(prompt.contains("thread:tracking-10"))
        #expect(!prompt.contains("thread:tracking-11"))
        #expect(prompt.contains("EXACT key"))
        #expect(prompt.contains("Do not emit a fabricated observation"))
        let prepared = try await plan.prepare()
        #expect(prepared.system.contains("user authorized the resulting read-state change"))
        #expect(!prepared.system.contains("Do not open mail rows or cells"))
        #expect(prepared.system.contains("otherwise unknown"))
        #expect(collection.policy(trackedItems: tracked) == .sourceFollowUp)
        #expect(collection.policy(trackedItems: []) == .sourceRead)
    }

    private final class FakeClient: ConversationClient {
        typealias Body = @MainActor (String, [[String: Any]], [[String: Any]], @escaping ToolExecutor) async throws -> String
        var effort = "medium"
        var maxTokens = 1024
        var maxToolRounds = 8
        var shouldStop: () -> Bool = { false }
        let body: Body
        init(_ body: @escaping Body) { self.body = body }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            let result = try await body(system, tools, messages, executor)
            messages.append(["role": "assistant", "content": [["type": "text", "text": result]]])
            return ClaudeReply(text: result, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 0)
        }
    }
}
