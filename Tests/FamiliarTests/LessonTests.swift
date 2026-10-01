import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

/// What the person teaches, "Matters to me" and why on a run's results, thumbs and words on a card, is kept as
/// lessons with the cards, and the card step reads a job's newest lessons beside its rules, so what matters to this
/// person shapes their cards. Teaching never sorts mail already sorted again.
@Suite @MainActor
struct LessonTests {
    // MARK: - Keeping lessons

    @Test func oneLessonPerItemNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let morning = fixture.morning
        let first = Date(timeIntervalSince1970: 1_000_000), later = first.addingTimeInterval(60)
        try morning.teach(fixture.facts(1), verdict: .matters, at: first)
        try morning.teach(fixture.facts(1), why: "  The landlord needs an answer.  ", at: later)
        try morning.teach(fixture.facts(2), verdict: .notForMe, at: later)
        #expect(morning.lessons.map(\.key) == [fixture.key(2), fixture.key(1)])
        let lesson = try #require(morning.lesson(for: fixture.key(1)))
        #expect(lesson.verdict == .matters && lesson.why == "The landlord needs an answer." && lesson.taughtAt == later)
        #expect(lesson.title == "Message 1" && lesson.from == "Sender 1 <sender1@example.test>" && lesson.sourceName == "Morning mail")

        // Teaching the same thing again, as the rest and the run results both do, keeps the lesson and its time.
        try morning.teach(fixture.facts(1), verdict: .matters, at: later.addingTimeInterval(60))
        #expect(morning.lesson(for: fixture.key(1))?.taughtAt == later && morning.lessons.first?.key == fixture.key(2))

        // Taking a verdict back keeps the words; taking the words back too leaves nothing, so the lesson goes.
        try morning.teach(fixture.facts(1), verdict: nil)
        #expect(morning.lesson(for: fixture.key(1))?.verdict == nil && morning.lesson(for: fixture.key(1))?.why != nil)
        try morning.teach(fixture.facts(1), why: "  ")
        #expect(morning.lesson(for: fixture.key(1)) == nil)
        // Words alone are a lesson; nothing at all is not kept.
        try morning.teach(fixture.facts(3), why: "Never urgent.")
        try morning.teach(fixture.facts(4), verdict: nil)
        #expect(morning.lessons.map(\.key) == [fixture.key(3), fixture.key(2)])
        try morning.forgetLesson(key: fixture.key(2))
        #expect(morning.lessons.map(\.key) == [fixture.key(3)])
    }

    @Test func lessonsAreBoundedAndSurviveAReload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<(MorningLesson.limit + 5) {
            try fixture.morning.teach(fixture.facts(index), verdict: .notForMe, at: start.addingTimeInterval(Double(index)))
        }
        try fixture.morning.teach(fixture.facts(0), why: String(repeating: "a", count: 800), at: start.addingTimeInterval(1_000))
        #expect(fixture.morning.lessons.count == MorningLesson.limit)
        #expect(fixture.morning.lessons.first?.why?.count == MorningLesson.whyLimit)
        #expect(fixture.morning.lesson(for: fixture.key(1)) == nil)   // the oldest went
        let reloaded = MorningStore(directory: fixture.root.appendingPathComponent("morning"))
        #expect(reloaded.lessons == fixture.morning.lessons && reloaded.error == nil)
    }

    @Test func aRunsItemsCarryTheKeyTheCardStepUses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runID = try fixture.read(0..<2)
        let entry = try #require(fixture.sources.runStore.run(id: runID)?.entries.first)
        let items = SourceResultPresentation(entry: entry).items
        #expect(items.map(\.key) == [fixture.key(0), fixture.key(1)])
        #expect(items.first?.from == "Sender 0 <sender0@example.test>")
        let observations = CardGenerationInput.saved(in: fixture.sources, runID: runID, excluding: []).observations
        #expect(Set(observations.map(\.id)) == Set(items.compactMap(\.key)))
    }

    @Test func markingAResultTeachesWithoutMakingACard() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let teaching = ResultItemTeaching(morning: fixture.morning, teaching: RunTeaching(morning: fixture.morning), facts: fixture.facts(5))
        teaching.mark(true)
        #expect(fixture.morning.lesson(for: fixture.key(5))?.verdict == .matters && fixture.morning.cards.isEmpty)
        try fixture.morning.teach(fixture.facts(5), why: "From my landlord.")
        teaching.mark(false)
        #expect(fixture.morning.lessons.isEmpty)   // taking it back forgets the words too
    }

    // MARK: - The card step

    @Test func theCardStepReadsAJobsLessonsBesideItsRules() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = UUID()
        try fixture.morning.teach(fixture.facts(100), verdict: .matters)
        try fixture.morning.teach(fixture.facts(101), why: "Shipping updates never need me.")
        try fixture.morning.teach(fixture.facts(101), verdict: .notAtAll)
        try fixture.morning.teach(LessonFacts(key: "\(other.uuidString.lowercased()):x", sourceID: other, sourceName: "Work mail",
                                              title: "Secret project", from: nil), verdict: .matters)
        let service = fixture.service()
        try fixture.read(0..<3)
        await service.generate()?.value

        let input = try #require(fixture.inputs.first)
        let lessons = try #require(input["lessons"] as? [[String: Any]])
        #expect(lessons.count == 2)   // only this job's
        #expect(lessons.first?["verdict"] as? String == "not_at_all" && lessons.first?["why"] as? String == "Shipping updates never need me.")
        #expect(lessons.first?["title"] as? String == "Message 101" && lessons.first?["from"] as? String == "Sender 101 <sender101@example.test>")
        #expect(lessons.last?["verdict"] as? String == "matters" && lessons.last?["why"] == nil)
        #expect(!fixture.prompts[0].contains("Secret project"))
        #expect(fixture.systems.first?.contains("lessons, when present, are this person's own verdicts") == true)
        #expect(fixture.systems.first?.contains("Apply a lesson only to observations with the same sourceID") == true)
        #expect(fixture.systems.first?.contains("lesson titles and senders") == true)
        #expect(fixture.morning.workspace.cardGenerations?.last?.lessons == 2)
        #expect(service.status == "0 new · 0 updated · 0 resolved · used 2 things you taught")
    }

    @Test func withoutLessonsThePromptAndReceiptAreAsBefore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try fixture.read(0..<3)
        await service.generate()?.value
        #expect(fixture.inputs.first?["lessons"] == nil && !fixture.prompts[0].contains("\"lessons\""))
        #expect(fixture.morning.workspace.cardGenerations?.last?.lessons == nil)
        #expect(service.status == "0 new · 0 updated · 0 resolved")
    }

    @Test func eachJobsNewestLessonsAreRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<(MorningLesson.promptLimit + 5) {
            try fixture.morning.teach(fixture.facts(100 + index), verdict: .notForMe, at: start.addingTimeInterval(Double(index)))
        }
        let service = fixture.service()
        try fixture.read(0..<1)
        await service.generate()?.value
        let lessons = try #require(fixture.inputs.first?["lessons"] as? [[String: Any]])
        #expect(lessons.count == MorningLesson.promptLimit)
        #expect(lessons.first?["title"] as? String == "Message \(100 + MorningLesson.promptLimit + 4)")
    }

    @Test func teachingNeverSortsWhatWasSortedAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try fixture.read(0..<3)
        await service.generate()?.value
        try fixture.morning.teach(fixture.facts(1), verdict: .matters)
        try fixture.read(0..<3)
        await service.generate()?.value
        #expect(fixture.prompts.count == 1)   // the same mail read again asks the model nothing
        try fixture.read(0..<4)
        await service.generate()?.value
        #expect(fixture.prompts.count == 2 && fixture.sent.last == [fixture.key(3)])
        #expect((fixture.inputs.last?["lessons"] as? [[String: Any]])?.count == 1)
    }

    @Test func anItemsOwnLessonStaysOutWhileItIsSorted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.morning.teach(fixture.facts(1), verdict: .matters)
        try fixture.morning.teach(fixture.facts(100), verdict: .notForMe)
        let service = fixture.service()
        try fixture.read(0..<3)
        await service.generate()?.value
        let lessons = try #require(fixture.inputs.first?["lessons"] as? [[String: Any]])
        #expect(lessons.map { $0["title"] as? String } == ["Message 100"])
        #expect(fixture.morning.workspace.cardGenerations?.last?.lessons == 1)
    }

    @Test func onlyASortedItemCanBeTaughtAndACardOpens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var opened: [UUID] = []
        let teaching = RunTeaching(morning: fixture.morning, openCard: { opened.append($0) })
        let row = ResultItemTeaching(morning: fixture.morning, teaching: teaching, facts: fixture.facts(0))
        try fixture.read(0..<2)
        #expect(!row.isSorted && row.card == nil)   // it may yet become a card
        fixture.carding = [fixture.key(1)]
        let service = fixture.service()
        await service.generate()?.value
        #expect(row.isSorted && row.card == nil)
        let carded = ResultItemTeaching(morning: fixture.morning, teaching: teaching, facts: fixture.facts(1))
        let card = try #require(carded.card)
        #expect(card.tracking?.key == fixture.key(1))
        teaching.openCard(card.id)
        #expect(opened == [card.id])
    }

    // MARK: - Fixtures

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lessons-\(UUID())")
        let job = LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My inbox",
            scope: "Show what needs a reply", script: "imap-mail__today")
        let desktop = DesktopExecutionService(control: ComputerController(), activities: NativeActivityGate())
        let sources: CalendarStore
        let morning: MorningStore
        /// What each model call was given: its system prompt, its user text, the JSON in it, and its observation keys.
        var systems: [String] = []
        var prompts: [String] = []
        var inputs: [[String: Any]] = []
        var sent: [[String]] = []
        /// The observation keys the stand-in model makes a card for.
        var carding: Set<String> = []
        private var clock = Date().addingTimeInterval(-86_400)

        init() throws {
            sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
            morning = MorningStore(directory: root.appendingPathComponent("morning"))
            try sources.saveReadingSource(job)
        }

        func key(_ index: Int) -> String { CardObservation.key(sourceID: job.id, itemKey: "m\(index)@example.test") }

        func facts(_ index: Int) -> LessonFacts {
            LessonFacts(key: key(index), sourceID: job.id, sourceName: job.name, title: "Message \(index)",
                        from: "Sender \(index) <sender\(index)@example.test>")
        }

        @discardableResult
        func read(_ indices: Range<Int>) throws -> UUID {
            let rows: [[String: Any]] = indices.map { index in
                ["key": "m\(index)@example.test", "title": "Message \(index)", "from": "Sender \(index) <sender\(index)@example.test>",
                 "received": "2026-09-30T08:\(String(format: "%02d", index % 60)):00+00:00", "unread": true, "tab": "primary",
                 "preview": "Preview \(index)"]
            }
            let result: [String: Any] = ["mailbox": "INBOX", "arrived": rows.count, "returned": rows.count, "truncated": false, "items": rows]
            clock = clock.addingTimeInterval(60)
            let snapshot = try ScriptReading.snapshot(from: result, request: ReadingReadRequest(source: job), collectedAt: clock)
            try sources.saveReadingSnapshot(snapshot)
            return try #require(sources.runStore.runs.first { $0.entries.first?.readingSnapshot?.id == snapshot.id }?.id)
        }

        func service() -> CardGenerationService {
            CardGenerationService(morning: morning, sources: sources, desktop: desktop, config: { Config() }, makeClient: { _ in
                Client { system, _, messages, executor in
                    let text = ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                    let split = try #require(text.range(of: "\n\n"))
                    let input = try #require(JSONSerialization.jsonObject(with: Data(text[split.upperBound...].utf8)) as? [String: Any])
                    self.systems.append(system)
                    self.prompts.append(text)
                    self.inputs.append(input)
                    self.sent.append(try #require(input["observations"] as? [[String: Any]]).compactMap { $0["observationKey"] as? String })
                    let keys = self.sent.last ?? []
                    let proposals: [[String: Any]] = keys.filter(self.carding.contains).map { key in
                        ["observationKey": key, "title": "Reply to the sender", "meaning": "They are waiting on an answer from you.",
                         "options": [["title": "Draft a reply", "instruction": "Draft a short reply to the saved message.", "mode": "prepare"]]]
                    }
                    let submitted = await executor(CardGenerationSubmission.toolName, ["proposals": proposals], nil)
                    #expect(!submitted.isError)
                    return "Ready"
                }
            })
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
