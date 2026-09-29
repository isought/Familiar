import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct SourceRunRunnerTests {
    @Test func repeatedMailboxCollectionsRemainSeparateAfterRestartWithCapturedRules() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        var collectedTitle = "First morning message"
        var capturedSource = fixture.mail
        let runner = fixture.runner { _, _, messages, executor in
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.payload(source: capturedSource, messages: messages, title: collectedTitle)
            let result = await executor("submit_reading_collection", payload, nil)
            #expect(!result.isError)
            return "Read"
        }
        var finishedRuns: [UUID] = []
        runner.onRunFinished = { [weak runner] runID in
            #expect(runner?.isRunning == false)
            #expect(fixture.store.runStore.run(id: runID)?.status == .completed)
            #expect(fixture.store.runStore.run(id: runID)?.finishedAt != nil)
            finishedRuns.append(runID)
        }
        let first = try #require(runner.collect(source: capturedSource, requestedAt: fixture.day))
        await first.value
        capturedSource.scope = "Only unread messages on the first Primary page"
        try fixture.store.saveReadingSource(capturedSource)
        collectedTitle = "Second morning message"
        let second = try #require(runner.collect(source: capturedSource, requestedAt: fixture.day.addingTimeInterval(86_400)))
        await second.value

        let reopened = CalendarStore(directory: fixture.storeDirectory)
        let runs = reopened.runStore.runs.filter { $0.origin == .single }
        #expect(runs.count == 2)
        #expect(finishedRuns.count == 2)
        #expect(Set(finishedRuns) == Set(runs.map(\.id)))
        #expect(Set(runs.map(\.id)).count == 2)
        #expect(runs.allSatisfy { $0.status == .completed && $0.finishedAt != nil })
        let entries = runs.flatMap(\.entries)
        #expect(entries.allSatisfy { $0.state == .complete })
        let snapshots = entries.compactMap(\.readingSnapshot)
        #expect(Set(snapshots.flatMap { $0.items.map(\.title) }) == ["First morning message", "Second morning message"])
        #expect(snapshots.first { $0.items.first?.title == "First morning message" }?.source.scope == fixture.mail.scope)
        #expect(snapshots.first { $0.items.first?.title == "Second morning message" }?.source.scope == capturedSource.scope)
        #expect(reopened.latestReading(for: fixture.mail.id)?.items.first?.title == "Second morning message")
        #expect(fixture.desktop.tasks.history.first?.outcome == .completed)
    }

    @Test func stoppingBatchPersistsProgressAndKeepsEarlierResultAfterRestart() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var second = fixture.mail; second.id = UUID(); second.name = "Second inbox"
        var third = fixture.mail; third.id = UUID(); third.name = "Third inbox"
        let sources = [fixture.mail, second, third]
        for source in sources { try fixture.store.saveReadingSource(source) }
        var calls: [UUID] = []
        var secondEntered = false
        let runner = fixture.runner { _, _, messages, executor in
            let source = try #require(sources.first { Self.text(messages).contains($0.id.uuidString) })
            calls.append(source.id)
            let run = try #require(fixture.store.runStore.runs.first)
            let folder = try #require(fixture.store.runStore.directory(for: run.id))
            let disk = try SourceRunJSON.decoder().decode(SourceRunRecord.self,
                from: Data(contentsOf: folder.appendingPathComponent("run.json")))
            #expect(disk == run)
            #expect(disk.status == .running)
            if source.id == second.id {
                #expect(disk.entries.map(\.state) == [.complete, .reading, .waiting])
                #expect(disk.entries[0].readingSnapshot?.items.first?.title == "Current message")
            }
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.payload(source: source, messages: messages)
            let result = await executor("submit_reading_collection", payload, nil)
            #expect(!result.isError)
            if source.id == second.id {
                secondEntered = true
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return "Read"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        let runID = try #require(runner.currentRunID)
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(runner.collect(source: fixture.mail) == nil)
        #expect(fixture.store.runStore.runs.count == 1)
        let deadline = Date().addingTimeInterval(3)
        while !secondEntered, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(secondEntered)
        #expect(runner.stopActive())
        await task.value

        let reopened = CalendarStore(directory: fixture.storeDirectory)
        let run = try #require(reopened.runStore.run(id: runID))
        #expect(run.origin == .all)
        #expect(run.status == .stopped)
        #expect(run.finishedAt != nil)
        #expect(run.entries.map(\.state) == [.complete, .stopped, .notRun])
        #expect(run.entries.allSatisfy { $0.finishedAt != nil })
        #expect(run.entries[0].readingSnapshot != nil)
        #expect(run.entries[1].readingSnapshot == nil)
        #expect(run.entries[2].readingSnapshot == nil)
        #expect(calls == [fixture.mail.id, second.id])
        #expect(runner.currentRunID == runID)
        #expect(!runner.isRunning)
    }

    @Test func unavailableArchivePreventsProviderAndDesktopWork() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        try Data("Unavailable archive".utf8).write(to: #require(fixture.store.runStore.archiveDirectory))
        var providerCalls = 0
        let runner = fixture.runner { _, _, _, _ in providerCalls += 1; return "Unused" }
        #expect(runner.collect(source: fixture.mail, requestedAt: fixture.day) == nil)
        #expect(providerCalls == 0)
        #expect(runner.currentRunID == nil)
        #expect(runner.error?.contains("could not be saved") == true)
        #expect(fixture.store.runStore.runs.isEmpty)
        #expect(fixture.desktop.tasks.activeTask == nil)
        #expect(fixture.desktop.tasks.history.isEmpty)
        #expect(!runner.isRunning)
    }

    private static func text(_ messages: [[String: Any]]) -> String {
        ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-run-runner-\(UUID().uuidString)")
        var storeDirectory: URL { directory.appendingPathComponent("store") }
        let activities = NativeActivityGate()
        let day = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        let mail = LearnedReadingSource(kind: .mail, name: "Gmail inbox", meaning: "My incoming work mail",
            application: "Google Chrome", bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox",
            account: "employee@example.test", scope: "The first page of the Primary inbox",
            navigationHints: "Recognize Inbox and Primary", completionChecks: "Verify account, tab and displayed page range")
        lazy var store = CalendarStore(directory: storeDirectory)
        lazy var desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
        lazy var registry = ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: Config()))

        func payload(source: LearnedReadingSource, messages: [[String: Any]], title: String = "Current message", coverage: CalendarCoverage = .complete) throws -> [String: Any] {
            let marker = "Required requestID: "
            let line = try #require(SourceRunRunnerTests.text(messages).components(separatedBy: .newlines).first { $0.hasPrefix(marker) })
            let id = try #require(UUID(uuidString: String(line.dropFirst(marker.count))))
            return ["sourceID": source.id.uuidString, "requestID": id.uuidString, "coverage": coverage.rawValue,
                "coverageNotes": coverage == .complete ? ["Verified the full taught first page"] : ["Only the first visible rows could be read"],
                "accountEvidence": "Account menu displays employee@example.test", "sourceEvidence": "Address bar: \(source.url)",
                "scopeEvidence": "Inbox selected, Primary tab, requested page range verified",
                "items": [["title": title, "text": "Taylor · Visible snippet · 9:42 AM", "evidence": "Visible inbox row with subject, sender and snippet"]]]
        }

        func runner(_ body: @escaping FakeClient.Body) -> CalendarCollectionRunner {
            var settings = Config(); settings.allowControl = true
            return CalendarCollectionRunner(store: store, desktop: desktop, registry: registry, activities: activities,
                config: { settings }, makeClient: { _ in FakeClient(body) }, prepareExecution: { _, additional, evidence in
                    let read = ToolRoute(match: .tool(name: "read_screen"), definition: ["name": "read_screen"]) { _, _, _ in
                        evidence.observed(); return .text("Fresh observed source")
                    }
                    return PreparedExecution(system: "fixture", router: try ToolRouter(routes: additional + [read]))
                })
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
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
