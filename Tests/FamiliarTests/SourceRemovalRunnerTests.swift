import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct SourceRemovalRunnerTests {
    @Test func staleDirectReadsAndWrongSourceTypesAreRejectedBeforeProviderSetup() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveSource(fixture.calendar)
        try fixture.store.saveReadingSource(fixture.mail)
        try fixture.store.removeSource(id: fixture.calendar.id)
        try fixture.store.removeSource(id: fixture.mail.id)
        var factories = 0
        var settings = Config(); settings.allowControl = true
        let runner = CalendarCollectionRunner(store: fixture.store, desktop: fixture.desktop, registry: fixture.registry,
            activities: fixture.activities, config: { settings }, makeClient: { _ in
                factories += 1
                return FakeClient { _, _ in "Must not read" }
            })
        #expect(runner.collect(source: fixture.calendar, day: fixture.day) == nil)
        #expect(runner.error?.contains("removed") == true)
        #expect(runner.collect(source: fixture.mail, requestedAt: fixture.day) == nil)
        #expect(runner.error?.contains("removed") == true)

        // A source ID in the other collection is not membership in this type.
        var activeMail = fixture.mail; activeMail.id = UUID()
        try fixture.store.saveReadingSource(activeMail)
        var wrongCalendar = fixture.calendar; wrongCalendar.id = activeMail.id
        #expect(runner.collect(source: wrongCalendar, day: fixture.day) == nil)
        var activeCalendar = fixture.calendar; activeCalendar.id = UUID()
        try fixture.store.saveSource(activeCalendar)
        var wrongMail = fixture.mail; wrongMail.id = activeCalendar.id
        #expect(runner.collect(source: wrongMail, requestedAt: fixture.day) == nil)
        #expect(factories == 0)
        #expect(!runner.isRunning)
        #expect(fixture.desktop.tasks.activeTask == nil)
    }

    @Test func queuedRemovalSkipsItsProviderAndContinuesMixedBatch() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let later = fixture.extraMail()
        try fixture.store.saveSource(fixture.calendar)
        try fixture.store.saveReadingSource(fixture.mail)
        try fixture.store.saveReadingSource(later)
        var calls: [UUID] = []
        let runner = fixture.runner { messages, executor in
            let text = Self.text(messages)
            _ = await executor("read_screen", [:], nil)
            if text.contains(fixture.calendar.id.uuidString) {
                calls.append(fixture.calendar.id)
                try fixture.store.removeSource(id: fixture.mail.id)
                #expect(!(await executor("submit_calendar_collection", fixture.calendarPayload(), nil)).isError)
            } else {
                #expect(text.contains(later.id.uuidString))
                calls.append(later.id)
                let payload = try fixture.mailPayload(source: later, messages: messages)
                #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            }
            return "Collected"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value
        #expect(calls == [fixture.calendar.id, later.id])
        #expect(runner.batchResults.map(\.state) == [.complete, .notRun, .complete])
        #expect(runner.batchResults[1].message.contains("removed"))
        #expect(fixture.store.latest(for: fixture.calendar.id) != nil)
        #expect(fixture.store.latestReading(for: later.id) != nil)
        #expect(fixture.store.readingSources.map(\.id) == [later.id])
        #expect(fixture.store.removedSources.map(\.id) == [fixture.mail.id])
    }

    @Test func immediateFirstRemovalReleasesReservationAndRestoresStopBeforeContinuing() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveSource(fixture.calendar)
        try fixture.store.saveReadingSource(fixture.mail)
        var originalStops = 0
        fixture.desktop.peek.onStop = { originalStops += 1 }
        var calls = 0
        let runner = fixture.runner { messages, executor in
            calls += 1
            #expect(Self.text(messages).contains(fixture.mail.id.uuidString))
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.mailPayload(source: fixture.mail, messages: messages)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            return "Collected"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        #expect(fixture.desktop.tasks.activeTask != nil)
        // MainActor cannot start the worker until this synchronous removal ends.
        try fixture.store.removeSource(id: fixture.calendar.id)
        await task.value
        #expect(calls == 1)
        #expect(runner.batchResults.map(\.state) == [.notRun, .complete])
        #expect(!runner.isRunning)
        #expect(runner.activeSourceID == nil)
        #expect(fixture.desktop.tasks.activeTask == nil)
        #expect(!fixture.desktop.isBusy)
        fixture.desktop.peek.onStop?()
        #expect(originalStops == 1)
    }

    @Test func removalDuringPreparationCancelsOnlyCurrentSourceAndReleasesNativeOwnership() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let later = fixture.extraMail()
        try fixture.store.saveReadingSource(fixture.mail)
        try fixture.store.saveReadingSource(later)
        var preparationStarted = false
        var preparations = 0
        var calls = 0
        let runner = fixture.runner(prepare: { id, additional, evidence in
            preparations += 1
            if preparations == 1 {
                let plan = try await fixture.desktop.prepare(id: id, registry: fixture.registry, context: nil,
                    background: true, resolveFrontmost: false, policy: .sourceRead, additionalRoutes: additional,
                    lookAtScreen: { .text("Unused") })
                preparationStarted = true
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return plan
            }
            return try fixture.plan(additional: additional, evidence: evidence)
        }) { messages, executor in
            calls += 1
            #expect(Self.text(messages).contains(later.id.uuidString))
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.mailPayload(source: later, messages: messages)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            return "Collected"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        try await until { preparationStarted }
        #expect(fixture.desktop.isBusy)
        #expect(fixture.activities.current != nil)
        try fixture.store.removeSource(id: fixture.mail.id)
        await task.value
        #expect(preparations == 2)
        #expect(calls == 1)
        #expect(runner.batchResults.map(\.state) == [.notRun, .complete])
        #expect(fixture.activities.current == nil)
        #expect(!fixture.desktop.isBusy)
        #expect(fixture.desktop.control.pressRefusal == nil)
        #expect(fixture.desktop.tasks.activeTask == nil)
        #expect(fixture.store.latestReading(for: later.id) != nil)
    }

    @Test func removalAfterSubmissionDiscardsStagingKeepsArchiveAndContinuesBatch() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let later = fixture.extraMail()
        try fixture.store.saveReadingSource(fixture.mail)
        try fixture.store.saveReadingSource(later)
        let priorRequest = ReadingReadRequest(source: fixture.mail, requestedAt: fixture.day)
        let prior = try ReadingSubmission.parse(fixture.mailPayload(source: fixture.mail, requestID: priorRequest.id), request: priorRequest)
        try fixture.store.saveReadingSnapshot(prior)
        var calls: [UUID] = []
        var staged = false
        let runner = fixture.runner { messages, executor in
            let source = Self.text(messages).contains(fixture.mail.id.uuidString) ? fixture.mail : later
            calls.append(source.id)
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.mailPayload(source: source, messages: messages)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            if source.id == fixture.mail.id {
                staged = true
                try fixture.store.removeSource(id: source.id)
                // Even a provider that attempts another submission after removal
                // cannot replace the discarded staged result.
                #expect((await executor("submit_reading_collection", payload, nil)).isError)
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return "Collected"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value
        #expect(staged)
        #expect(calls == [fixture.mail.id, later.id])
        #expect(runner.batchResults.map(\.state) == [.failed, .complete])
        #expect(runner.batchResults[0].message.contains("removed"))
        #expect(fixture.store.latestReading(for: fixture.mail.id) == nil)
        #expect(fixture.store.readingSnapshots.map(\.sourceID) == [later.id])
        let archived = try #require(fixture.store.removedSources.first { $0.id == fixture.mail.id })
        #expect(archived.readingSnapshots == [prior])
        let reloaded = CalendarStore(directory: fixture.directory.appendingPathComponent("store"))
        #expect(reloaded.readingSources.map(\.id) == [later.id])
        #expect(reloaded.removedSources.first?.readingSnapshots == [prior])
    }

    @Test func editingActiveReadingProfileKeepsCapturedIdentityAndDoesNotCancel() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        let runner = fixture.runner { messages, executor in
            var edited = fixture.mail
            edited.name = "Updated label"
            edited.account = "different@example.test"
            try fixture.store.saveReadingSource(edited)
            #expect(!Task.isCancelled)
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.mailPayload(source: fixture.mail, messages: messages)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            return "Collected"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value
        #expect(runner.batchResults.map(\.state) == [.complete])
        #expect(fixture.store.readingSnapshots.first?.source == fixture.mail)
        #expect(fixture.store.readingSources.first?.account == "different@example.test")
        #expect(fixture.store.latestReading(for: fixture.mail.id) == nil)
    }

    private static func text(_ messages: [[String: Any]]) -> String {
        ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func until(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        try #require(condition())
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-removal-runner-\(UUID().uuidString)")
        let activities = NativeActivityGate()
        let day = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        let mail = LearnedReadingSource(kind: .mail, name: "Work inbox", meaning: "My incoming work mail",
            application: "Google Chrome", bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox",
            account: "employee@example.test", scope: "First page of the Primary inbox")
        let calendar = LearnedCalendarSource(name: "Work calendar", meaning: "My work meetings", application: "Outlook",
            bundleID: "com.microsoft.Outlook", account: "employee@example.test", calendarName: "Calendar", timeZoneID: "America/New_York")
        lazy var store = CalendarStore(directory: directory.appendingPathComponent("store"))
        lazy var desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
        lazy var registry = ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: Config()))

        func extraMail() -> LearnedReadingSource {
            var extra = mail
            extra.id = UUID(); extra.name = "Later inbox"; extra.url = "https://mail.google.com/mail/u/1/#inbox"
            return extra
        }

        func mailPayload(source: LearnedReadingSource, messages: [[String: Any]]) throws -> [String: Any] {
            let marker = "Required requestID: "
            let line = try #require(SourceRemovalRunnerTests.text(messages).components(separatedBy: .newlines).first { $0.hasPrefix(marker) })
            let id = try #require(UUID(uuidString: String(line.dropFirst(marker.count))))
            return mailPayload(source: source, requestID: id)
        }

        func mailPayload(source: LearnedReadingSource, requestID: UUID) -> [String: Any] {
            ["sourceID": source.id.uuidString, "requestID": requestID.uuidString, "coverage": "complete",
             "coverageNotes": ["Verified the full taught page"], "accountEvidence": "Account: \(source.account)",
             "sourceEvidence": "Address: \(source.url)", "scopeEvidence": "Primary inbox, page 1–1 of 1",
             "items": [["title": "Current message", "text": "Visible sender and snippet", "evidence": "Visible inbox row"]]]
        }

        func calendarPayload() -> [String: Any] {
            ["sourceID": calendar.id.uuidString, "day": "2026-09-28", "timeZoneID": calendar.timeZoneID,
             "coverage": "complete", "coverageNotes": ["Inspected all hours and all-day area"],
             "accountEvidence": "Account: employee@example.test", "calendarEvidence": "Calendar selected",
             "dateEvidence": "September 28 2026, Eastern time", "events": []]
        }

        func plan(additional: [ToolRoute], evidence: CalendarCollectionEvidence) throws -> PreparedExecution {
            let read = ToolRoute(match: .tool(name: "read_screen"), definition: ["name": "read_screen"]) { _, _, _ in
                evidence.observed(); return .text("Fresh observed source")
            }
            return PreparedExecution(system: "fixture", router: try ToolRouter(routes: additional + [read]))
        }

        func runner(prepare: CalendarCollectionRunner.PrepareExecution? = nil,
                    _ body: @escaping FakeClient.Body) -> CalendarCollectionRunner {
            var settings = Config(); settings.allowControl = true
            return CalendarCollectionRunner(store: store, desktop: desktop, registry: registry, activities: activities,
                config: { settings }, makeClient: { _ in FakeClient(body) },
                prepareExecution: prepare ?? { _, additional, evidence in try self.plan(additional: additional, evidence: evidence) })
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class FakeClient: ConversationClient {
        typealias Body = @MainActor ([[String: Any]], @escaping ToolExecutor) async throws -> String
        var effort = "medium"
        var maxTokens = 1024
        var maxToolRounds = 8
        var shouldStop: () -> Bool = { false }
        let body: Body
        init(_ body: @escaping Body) { self.body = body }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            let text = try await body(messages, executor)
            messages.append(["role": "assistant", "content": [["type": "text", "text": text]]])
            return ClaudeReply(text: text, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 0)
        }
    }
}
