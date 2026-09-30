import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

/// The card step judges each item once: reading the same mail again asks the model nothing, so a message it passed
/// over can't come back as a card on the next run. New or changed items, and everything after a rules change, are
/// judged again; cards and the attention ledger still see the whole read.
@Suite @MainActor
struct CardJudgmentTests {
    @Test func aSecondStepOverTheSameReadAsksTheModelNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        fixture.carding = [fixture.key(3), fixture.key(17), fixture.key(40)]
        let first = try fixture.read(0..<48)
        await service.generate(runID: first)?.value
        #expect(fixture.sent.map(\.count) == [48] && fixture.morning.cards.count == 3)
        #expect(service.status == "3 new · 0 updated · 0 resolved")

        fixture.carding = Set((0..<48).map(fixture.key))   // a call now would card everything it was sent
        let second = try fixture.read(0..<48)
        await service.generate(runID: second)?.value
        #expect(fixture.sent.count == 1 && fixture.morning.cards.count == 3)
        #expect(fixture.desktop.tasks.history.count == 1)   // no task was started for it either
        #expect(fixture.morning.workspace.cardGenerations?.map(\.runIDs) == [[first], [second]])
        #expect(service.status == "Nothing new to sort: 48 already sorted." && service.error == nil)
    }

    @Test func changedRulesJudgeTheWholeReadAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try fixture.read(0..<48)
        await service.generate()?.value
        fixture.job.scope = "Only bills and deadlines"
        try fixture.sources.saveReadingSource(fixture.job)
        try fixture.read(0..<48)
        await service.generate()?.value
        #expect(fixture.sent.map(\.count) == [48, 48])

        fixture.job.meaning = "My personal inbox"
        try fixture.sources.saveReadingSource(fixture.job)
        try fixture.read(0..<48)
        await service.generate()?.value
        #expect(fixture.sent.map(\.count) == [48, 48, 48])
    }

    @Test func anOverlappingReadSendsOnlyTheNewMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try fixture.read(0..<48)
        await service.generate()?.value
        fixture.carding = [fixture.key(48)]
        try fixture.read(1..<49)   // the next read reaches back an hour: 47 it has seen and one new
        await service.generate()?.value
        #expect(fixture.sent.last == [fixture.key(48)])
        #expect(fixture.morning.cards.map { $0.tracking?.key } == [fixture.key(48)])
        #expect(service.status == "1 new · 0 updated · 0 resolved · 47 already sorted")
    }

    @Test func readingOrStarringMailIsNotNewButAChangedScreenReadIs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try fixture.read(0..<3)
        try fixture.readTaught("Budget review is due Friday")
        await service.generate()?.value
        #expect(Set(fixture.sent.joined()) == Set((0..<3).map(fixture.key) + [fixture.taughtKey]))

        let flipped = try fixture.read(0..<3, flipped: true)
        let text = try #require(fixture.sources.runStore.run(id: flipped)?.entries.first?.readingSnapshot?.items.first?.text)
        #expect(text.contains("read · starred") && text.contains("marked important"))   // its facts did change
        try fixture.readTaught("Budget review moved to Monday")
        await service.generate()?.value
        #expect(fixture.sent.count == 2 && fixture.sent.last == [fixture.taughtKey])
    }

    @Test func aFailedOrStoppedStepRecordsNoJudgments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        fixture.fail = true
        try fixture.read(0..<3)
        await service.generate()?.value
        #expect(service.error?.contains("unavailable") == true && fixture.morning.workspace.judgments == nil)

        fixture.fail = false
        await service.generate()?.value
        let judged = try #require(fixture.morning.workspace.judgments)
        #expect(fixture.sent.map(\.count) == [3, 3] && judged.count == 3)

        fixture.fail = true
        try fixture.read(0..<4)
        await service.generate()?.value
        #expect(service.error != nil && fixture.morning.workspace.judgments == judged)

        fixture.fail = false
        fixture.afterSubmit = { service.stop() }
        await service.generate()?.value
        #expect(service.status == "Card generation stopped." && fixture.morning.workspace.judgments == judged)

        fixture.afterSubmit = nil
        await service.generate()?.value
        #expect(Array(fixture.sent.dropFirst(2)) == [[fixture.key(3)], [fixture.key(3)], [fixture.key(3)]])
        #expect(fixture.morning.workspace.judgments?.count == 4 && service.error == nil)
    }

    @Test func anUpdatedInstallCountsWhatItAlreadySorted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // What the app did before judgments were kept: cards and a receipt for each read, nothing more.
        try fixture.read(0..<48)
        try fixture.readTaught("Budget review is due Friday")
        let before = CardGenerationInput.saved(in: fixture.sources, runID: nil, excluding: [])
        try fixture.morning.applyCardGeneration(observations: before.observations,
            proposals: [Fixture.card(fixture.key(3))], runIDs: before.runIDs)
        #expect(fixture.morning.workspace.judgments == nil && before.runIDs.count == 2)

        // The first step after updating reads only the other job, yet keeps what the mail job sorted.
        let service = fixture.service()
        try fixture.readTaught("Budget review moved to Monday")
        await service.generate()?.value
        #expect(fixture.sent == [[fixture.taughtKey]])
        try fixture.read(0..<49)
        await service.generate()?.value
        #expect(fixture.sent.last == [fixture.key(48)])
        #expect(Set((fixture.morning.workspace.judgments ?? [:]).keys) == Set((0..<49).map(fixture.key) + [fixture.taughtKey]))
        #expect(fixture.morning.cards.count == 1)
    }

    @Test func judgmentsSurviveAReloadAndOlderWorkspacesStillLoad() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.read(0..<3)
        let service = fixture.service()
        await service.generate()?.value
        let judged = try #require(fixture.morning.workspace.judgments)
        #expect(judged.count == 3)

        fixture.morning = MorningStore(directory: fixture.root.appendingPathComponent("morning"))
        #expect(fixture.morning.error == nil && fixture.morning.workspace.judgments == judged)
        try fixture.read(0..<3)
        let restarted = fixture.service()
        await restarted.generate()?.value
        #expect(fixture.sent.count == 1 && restarted.status == "Nothing new to sort: 3 already sorted.")

        // A workspace row saved before judgments were kept, and one saved without any, look the same.
        let older = #"{"version":1,"folders":[],"people":[],"cards":[],"workItems":[],"samplesLoaded":false}"#
        #expect(try JSONDecoder().decode(MorningWorkspace.self, from: Data(older.utf8)).judgments == nil)
        #expect(!String(decoding: try JSONEncoder().encode(MorningWorkspace()), as: UTF8.self).contains("judgments"))
    }

    @Test func judgmentsUnseenForThirtyDaysAreDropped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-judgment-prune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MorningStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000), day: TimeInterval = 24 * 3_600
        try store.applyCardGeneration(observations: [], proposals: [], runIDs: [UUID()], judged: ["old": "a", "kept": "b"], at: start)
        try store.applyCardGeneration(observations: [], proposals: [], runIDs: [UUID()], judged: ["kept": "b"], at: start.addingTimeInterval(20 * day))
        try store.applyCardGeneration(observations: [], proposals: [], runIDs: [UUID()], at: start.addingTimeInterval(31 * day))
        #expect(store.workspace.judgments?.count == 2)   // a step that records nothing drops nothing
        try store.applyCardGeneration(observations: [], proposals: [], runIDs: [UUID()], judged: ["new": "c"], at: start.addingTimeInterval(31 * day))
        let judgments = try #require(store.workspace.judgments)
        #expect(Set(judgments.keys) == ["kept", "new"])
        #expect(judgments["kept"] == CardJudgment(revision: "b", seenAt: start.addingTimeInterval(20 * day)))
        #expect(judgments["new"] == CardJudgment(revision: "c", seenAt: start.addingTimeInterval(31 * day)))
    }

    @Test func aJudgmentUnseenForThirtyDaysNoLongerCounts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // All three judged 31 days ago and two of them again 29 days ago; no step has run since to drop the old one.
        let first = try fixture.read(0..<3)
        let revisions = CardGenerationInput.saved(in: fixture.sources, runID: first, excluding: []).revisions
        let day: TimeInterval = 24 * 3_600
        try fixture.morning.applyCardGeneration(observations: [], proposals: [], runIDs: [first],
            judged: revisions, at: Date().addingTimeInterval(-31 * day))
        try fixture.morning.applyCardGeneration(observations: [], proposals: [], runIDs: [UUID()],
            judged: revisions.filter { $0.key != fixture.key(0) }, at: Date().addingTimeInterval(-29 * day))
        #expect(fixture.morning.workspace.judgments?.count == 3)

        try fixture.read(0..<3)
        let service = fixture.service()
        await service.generate()?.value
        #expect(fixture.sent == [[fixture.key(0)]])
        #expect(service.status == "0 new · 0 updated · 0 resolved · 2 already sorted")
        let judged = try #require(fixture.morning.workspace.judgments)
        #expect(Set(judged.keys) == Set((0..<3).map(fixture.key)) && judged.values.allSatisfy { Date().timeIntervalSince($0.seenAt) < 60 })
    }

    @Test func cardsAndTheLedgerStillSeeTheWholeRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        var sorted: [[String]] = []
        service.onSorted = { observations, _ in sorted.append(observations.map(\.id)) }
        fixture.carding = [fixture.key(1), fixture.taughtKey]
        let first = try fixture.read(0..<3)
        try fixture.readTaught("Budget review is due Friday")
        await service.generate()?.value
        let card = try #require(fixture.morning.cards.first { $0.tracking?.key == fixture.key(1) })
        #expect(card.tracking?.lastRunID == first && fixture.morning.cards.count == 2)

        // Read again after it was opened and starred: the model is asked nothing, but the card follows its source.
        let second = try fixture.read(0..<3, flipped: true)
        await service.generate()?.value
        #expect(fixture.sent.count == 1)
        #expect(sorted.map(\.count) == [4, 3] && Set(sorted[1]) == Set((0..<3).map(fixture.key)))
        let followed = try #require(fixture.morning.cards.first { $0.id == card.id })
        #expect(followed.title == card.title && followed.options == card.options)
        #expect(followed.tracking?.lastRunID == second && followed.tracking!.lastSeenAt > card.tracking!.lastSeenAt)
        #expect(followed.tracking?.changes.last?.message == "Source information changed.")
        #expect(followed.sources.first?.excerpt.contains("starred") == true)
        #expect(service.status == "0 new · 1 updated · 0 resolved · 3 already sorted")

        // A resolved item needs no judging, and its card is still resolved.
        try fixture.readTaught("Budget signed off; nothing left to review", state: .resolved)
        await service.generate()?.value
        #expect(fixture.sent.count == 1)
        #expect(fixture.morning.cards.first { $0.tracking?.key == fixture.taughtKey }?.isResolved == true)
        #expect(service.status == "0 new · 0 updated · 1 resolved")
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("card-judgment-\(UUID())")
        var job = LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My inbox",
            scope: "Show what needs a reply", script: "imap-mail__today")
        let taught = LearnedReadingSource(kind: .mail, name: "Work mail", meaning: "My work inbox",
            url: "https://mail.example.test/inbox", scope: "Recent unread messages")
        let desktop = DesktopExecutionService(control: ComputerController(), activities: NativeActivityGate())
        let sources: CalendarStore
        var morning: MorningStore
        /// The observation keys each model call was sent, and the ones it makes a card for.
        var sent: [[String]] = []
        var carding: Set<String> = []
        var fail = false
        var afterSubmit: (() -> Void)?
        private var clock = Date().addingTimeInterval(-86_400)

        init() throws {
            sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
            morning = MorningStore(directory: root.appendingPathComponent("morning"))
            try sources.saveReadingSource(job)
            try sources.saveReadingSource(taught)
        }

        func key(_ index: Int) -> String { CardObservation.key(sourceID: job.id, itemKey: "m\(index)@example.test") }
        var taughtKey: String { CardObservation.key(sourceID: taught.id, itemKey: "thread-9") }

        /// One script read of these messages, each a minute after the last; `flipped` reads them opened, starred and
        /// marked important.
        @discardableResult
        func read(_ indices: Range<Int>, flipped: Bool = false) throws -> UUID {
            let rows: [[String: Any]] = indices.map { index in
                ["key": "m\(index)@example.test", "title": "Message \(index)", "from": "Sender \(index) <sender\(index)@example.test>",
                 "received": "2026-09-30T08:\(String(format: "%02d", index % 60)):00+00:00", "unread": !flipped, "starred": flipped,
                 "important": flipped, "tab": "primary", "preview": "Preview \(index)"]
            }
            let result: [String: Any] = ["account": "me@example.test", "mailbox": "INBOX", "since": "2026-09-29T12:00:00+00:00",
                "arrived": rows.count, "returned": rows.count, "truncated": false, "items": rows]
            let snapshot = try ScriptReading.snapshot(from: result, request: ReadingReadRequest(source: job), collectedAt: tick())
            try sources.saveReadingSnapshot(snapshot)
            return try #require(sources.runStore.runs.first { $0.entries.first?.readingSnapshot?.id == snapshot.id }?.id)
        }

        /// One read of a mail window the person taught: a screen read, with no mail facts.
        @discardableResult
        func readTaught(_ text: String, state: ObservedItemState = .open) throws -> UUID {
            let item = ReadingItem(id: "row-\(UUID())", title: "Budget review", text: text, evidence: "Visible row: \(text)",
                url: "https://mail.example.test/thread/9", identityKey: "thread-9", identityEvidence: "Thread permalink 9",
                observedState: state, stateEvidence: text)
            let snapshot = ReadingSnapshot(requestID: UUID(), sourceID: taught.id, source: taught, collectedAt: tick(), items: [item],
                coverage: .complete, accountEvidence: "Current account", sourceEvidence: "Inbox", scopeEvidence: "Recent rows")
            try sources.saveReadingSnapshot(snapshot)
            return try #require(sources.runStore.runs.first { $0.entries.first?.readingSnapshot?.id == snapshot.id }?.id)
        }

        private func tick() -> Date {
            clock = clock.addingTimeInterval(60)
            return clock
        }

        func service() -> CardGenerationService {
            CardGenerationService(morning: morning, sources: sources, desktop: desktop, config: { Config() }, makeClient: { _ in
                Client { _, _, messages, executor in
                    let keys = try Self.keys(in: messages)
                    self.sent.append(keys)
                    if self.fail { throw MorningStoreError.invalid("The model is unavailable.") }
                    let submitted = await executor(CardGenerationSubmission.toolName,
                        ["proposals": keys.filter(self.carding.contains).map(Self.row)], nil)
                    #expect(!submitted.isError)
                    self.afterSubmit?()
                    return "Ready"
                }
            })
        }

        static func row(_ key: String) -> [String: Any] {
            ["observationKey": key, "title": "Reply to the sender", "meaning": "They are waiting on an answer from you.",
             "options": [["title": "Draft a reply", "instruction": "Draft a short reply to the saved message.", "mode": "prepare"]]]
        }

        static func card(_ key: String) -> CardProposal {
            CardProposal(observationKey: key, title: "Reply to the sender", meaning: "They are waiting on an answer from you.",
                action: MorningAction(title: "Draft a reply", instruction: "Draft a short reply to the saved message."))
        }

        private static func keys(in messages: [[String: Any]]) throws -> [String] {
            let text = ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            let split = try #require(text.range(of: "\n\n"))
            let object = try #require(JSONSerialization.jsonObject(with: Data(text[split.upperBound...].utf8)) as? [String: Any])
            return try #require(object["observations"] as? [[String: Any]]).compactMap { $0["observationKey"] as? String }
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
