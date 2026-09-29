import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct GeneratedCardStoreTests {
    @Test func generationsCarryForwardDeduplicateAndKeepLatestFactsAfterRestart() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let first = observation()
        let initial = try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        #expect(initial.created == 1)
        let identity = try #require(store.cards.first?.id)
        let original = store.workspace
        #expect(try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID]) == CardGenerationSummary())
        #expect(store.workspace == original)
        let changed = next(first, excerpt: "The requested deadline is now Friday.")
        #expect(try store.applyCardGeneration(observations: [changed], proposals: [proposal(changed)], runIDs: [changed.runID]).updated == 1)
        #expect(store.cards.count == 1 && store.cards[0].id == identity)
        #expect(store.cards[0].sources[0].excerpt == changed.excerpt)
        _ = try store.applyCardGeneration(observations: [], proposals: [], runIDs: [UUID()])
        #expect(!store.cards[0].isResolved)
        #expect(MorningStore(directory: fixture.directory).workspace == store.workspace)
        #expect(store.trackedItems(sourceID: first.sourceID).first?.key == first.itemKey.lowercased())
    }

    @Test func explicitResolutionReopensOnlyOnNewerEvidenceAndHumanResolutionStaysSticky() throws {
        let store = MorningStore(repository: MemoryRepository())
        let first = observation()
        _ = try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        let id = store.cards[0].id
        var resolved = next(first, excerpt: "A reply is visible.")
        resolved.state = .resolved; resolved.stateEvidence = "Your reply appears in the conversation."
        #expect(try store.applyCardGeneration(observations: [resolved], proposals: [], runIDs: [resolved.runID]).resolved == 1)
        #expect(store.cards[0].isResolved)
        var stale = first; stale.runID = UUID()
        _ = try store.applyCardGeneration(observations: [stale], proposals: [proposal(stale)], runIDs: [stale.runID])
        #expect(store.cards[0].isResolved && store.cards[0].sources[0].excerpt == resolved.excerpt)
        let reopened = next(resolved, excerpt: "A new explicit question needs a response.", state: .open)
        _ = try store.applyCardGeneration(observations: [reopened], proposals: [proposal(reopened)], runIDs: [reopened.runID])
        #expect(!store.cards[0].isResolved)
        try store.setCardResolution(cardID: id, resolved: true)
        let later = next(reopened, excerpt: "Still an open question", state: .open)
        _ = try store.applyCardGeneration(observations: [later], proposals: [proposal(later)], runIDs: [later.runID])
        #expect(store.cards[0].isResolved && store.cards[0].tracking?.resolvedByUser == true)
        try store.setCardResolution(cardID: id, resolved: false)
        #expect(!store.cards[0].isResolved)
    }

    @Test func humanEditsAndDecisionsSurviveGenerationWhileSourceFactsRefresh() throws {
        let store = MorningStore(repository: MemoryRepository())
        let first = observation()
        _ = try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        var card = store.cards[0]
        card.title = "My own priority"
        try store.saveCard(card)
        try store.updateCardContext(cardID: card.id, context: "Wait until I speak to Avery.", actionInstruction: "Prepare options; don't promise a date.")
        try store.setDisposition(cardID: card.id, to: .ignored)
        let changed = next(first, excerpt: "New facts from the source")
        _ = try store.applyCardGeneration(observations: [changed], proposals: [proposal(changed, title: "A generated replacement")], runIDs: [changed.runID])
        #expect(store.cards[0].title == "My own priority")
        #expect(store.cards[0].action.instruction == "Prepare options; don't promise a date.")
        #expect(store.cards[0].personalContext == "Wait until I speak to Avery.")
        #expect(store.cards[0].disposition == .ignored)
        #expect(store.cards[0].sources[0].excerpt == changed.excerpt)
        #expect(store.trackedItems(sourceID: first.sourceID).isEmpty)
    }

    @Test func acceptedWorkKeepsItsSnapshotAndPreparedResultLeavesMatterOpen() throws {
        let store = MorningStore(repository: MemoryRepository())
        let first = observation()
        _ = try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        let id = store.cards[0].id
        try store.setDisposition(cardID: id, to: .mine)
        let accepted = try store.enqueue(cardID: id)
        try store.updateCardContext(cardID: id, context: "New context after acceptance", actionInstruction: "A changed future action")
        #expect(store.workItems[0] == accepted)
        try store.updateWork(id: accepted.id, status: .completed, result: "A draft is ready")
        #expect(store.cards[0].disposition == .mine)
        #expect(!store.cards[0].isResolved)
        #expect(store.workItems[0].card == accepted.card && store.workItems[0].action == accepted.action)
        let queued = try store.enqueue(cardID: id)
        try store.setCardResolution(cardID: id, resolved: true)
        #expect(store.workItems.first { $0.id == queued.id }?.status == .cancelled)
        #expect(store.cards[0].isResolved)
        #expect(throws: MorningStoreError.self) { try store.enqueue(cardID: id) }
    }

    @Test func generationCannotCreateResolvedCardsOrPublishReceiptsAfterFailedSave() throws {
        let repository = MemoryRepository()
        let store = MorningStore(repository: repository)
        var finished = observation(); finished.state = .resolved; finished.stateEvidence = "A reply was observed"
        _ = try store.applyCardGeneration(observations: [finished], proposals: [proposal(finished)], runIDs: [finished.runID])
        #expect(store.cards.isEmpty)
        let first = observation()
        let before = store.workspace
        repository.failWrites = true
        #expect(throws: MorningStoreError.self) {
            try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        }
        #expect(store.workspace == before)
        repository.failWrites = false
        #expect(try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID]).created == 1)
    }

    @Test func validLegacyWorkspaceMigratesOnceWithoutChangingOriginalJSON() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        var old = MorningWorkspace()
        old.people = [MorningPerson(name: "Avery")]
        old.cards = [MorningCard(folderID: old.folders[0].id, title: "Keep my existing card", action: MorningAction(title: "Draft", instruction: "Prepare a reply"))]
        let original = try JSONEncoder().encode(old)
        let legacy = fixture.directory.appendingPathComponent("workspace.json")
        try original.write(to: legacy)
        let store = MorningStore(directory: fixture.directory)
        #expect(store.error == nil && store.workspace == old)
        #expect(try Data(contentsOf: legacy) == original)
        try store.saveFolder(MorningFolder(name: "After migration"))
        #expect(MorningStore(directory: fixture.directory).workspace == store.workspace)
        #expect(try Data(contentsOf: legacy) == original)
        let data = try Data(contentsOf: fixture.directory.appendingPathComponent("morning.sqlite"))
        #expect(String(decoding: data.prefix(15), as: UTF8.self) == "SQLite format 3")
    }

    @Test func sqliteUniqueTrackingConstraintRollsBackWholeWorkspace() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let first = observation()
        _ = try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        let before = store.workspace
        var duplicate = before.cards[0]; duplicate.id = UUID()
        var invalid = before; invalid.cards.append(duplicate)
        #expect(throws: MorningStoreError.self) { try SQLiteMorningRepository(directory: fixture.directory).save(invalid) }
        #expect(MorningStore(directory: fixture.directory).workspace == before)
    }

    private func observation() -> CardObservation {
        CardObservation(runID: UUID(), sourceID: UUID(), itemKey: "Mail-123", sourceName: "Inbox", kind: "Mail", title: "Please confirm the date",
            excerpt: "Avery asks for a delivery date.", url: "https://mail.example.test/thread/123", identityEvidence: "Thread URL and sender Avery",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000), state: .open, stateEvidence: "A visible question awaits a response.")
    }
    private func next(_ original: CardObservation, excerpt: String, state: ObservedItemState = .open) -> CardObservation {
        var value = original
        value.runID = UUID(); value.observedAt = original.observedAt.addingTimeInterval(60)
        value.excerpt = excerpt; value.state = state; value.stateEvidence = "Visible source state: \(state.rawValue)"
        return value
    }
    private func proposal(_ observation: CardObservation, title: String = "Respond to Avery") -> CardProposal {
        CardProposal(observationKey: observation.id, title: title, summary: observation.excerpt,
            rationale: "A response was requested", timing: "Today", unknowns: "Confirmed date",
            action: MorningAction(title: "Prepare reply", instruction: "Draft a reply using the supplied facts"))
    }
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("generated-card-tests-\(UUID())")
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
    private final class MemoryRepository: MorningRepository {
        var workspace: MorningWorkspace?
        var failWrites = false
        func load() throws -> LoadedMorningWorkspace? { workspace.map { LoadedMorningWorkspace(workspace: $0) } }
        func save(_ workspace: MorningWorkspace) throws {
            if failWrites { throw MorningStoreError.unavailable("Temporarily unavailable") }
            self.workspace = workspace
        }
    }
}
