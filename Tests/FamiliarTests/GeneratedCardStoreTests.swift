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

    @Test func regenerationRewritesALongCardAndKeepsOptionIDsStable() throws {
        let repository = MemoryRepository()
        let first = observation()
        _ = try MorningStore(repository: repository).applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        // A card written before the three-part shape: long summary, timing and unknowns.
        var legacy = try #require(repository.workspace)
        legacy.cards[0].summary = String(repeating: "Avery restated at length. ", count: 80)
        legacy.cards[0].timing = "Before Friday"; legacy.cards[0].unknowns = "The confirmed date"
        repository.workspace = legacy
        let store = MorningStore(repository: repository)

        let changed = next(first, excerpt: "Avery asks again for the date.")
        let options = threeOptions(changed)
        #expect(try store.applyCardGeneration(observations: [changed], proposals: [options], runIDs: [changed.runID]).updated == 1)
        let card = store.cards[0]
        #expect(card.rationale == options.meaning && card.meaning == options.meaning)
        #expect(card.summary.isEmpty && card.timing.isEmpty && card.unknowns.isEmpty)
        #expect(card.options.map(\.title) == ["Prepare reply", "Ask for a range", "Propose Friday"])
        let ids = card.options.map(\.id), history = card.tracking?.changes.count

        var again = changed; again.runID = UUID(); again.observedAt = changed.observedAt.addingTimeInterval(60)   // same facts
        #expect(try store.applyCardGeneration(observations: [again], proposals: [threeOptions(again)], runIDs: [again.runID]).updated == 0)
        #expect(store.cards[0].options.map(\.id) == ids)
        #expect(store.cards[0].tracking?.changes.count == history)
    }

    @Test func aCardYouEditedKeepsItsMeaningAndOptions() throws {
        let store = MorningStore(repository: MemoryRepository())
        let first = observation()
        _ = try store.applyCardGeneration(observations: [first], proposals: [threeOptions(first)], runIDs: [first.runID])
        var edited = store.cards[0]
        edited.rationale = "My own words."
        edited.alternatives = nil   // the editor builds a fresh card without the other options
        try store.saveCard(edited)
        #expect(store.cards[0].alternatives?.count == 2)

        let changed = next(first, excerpt: "New facts arrived.")
        _ = try store.applyCardGeneration(observations: [changed], proposals: [proposal(changed)], runIDs: [changed.runID])
        #expect(store.cards[0].rationale == "My own words.")
        #expect(store.cards[0].options.map(\.title) == ["Prepare reply", "Ask for a range", "Propose Friday"])
    }

    @Test func cardsSavedBeforeOptionsStillLoad() throws {
        let store = MorningStore(repository: MemoryRepository())
        let first = observation()
        _ = try store.applyCardGeneration(observations: [first], proposals: [proposal(first)], runIDs: [first.runID])
        let data = try JSONEncoder().encode(store.cards[0])
        #expect(!String(decoding: data, as: UTF8.self).contains("alternatives"))   // no options: encoded exactly as before
        let decoded = try JSONDecoder().decode(MorningCard.self, from: data)
        #expect(decoded.alternatives == nil && decoded.options.count == 1 && decoded == store.cards[0])
    }

    private func threeOptions(_ observation: CardObservation) -> CardProposal {
        CardProposal(observationKey: observation.id, title: "Avery needs a delivery date", meaning: "Avery can't plan until you confirm a date.",
            action: MorningAction(title: "Prepare reply", instruction: "Draft a reply using the supplied facts"),
            alternatives: [MorningAction(title: "Ask for a range", instruction: "Draft a reply asking which dates work"),
                           MorningAction(title: "Propose Friday", instruction: "Draft a reply proposing Friday")])
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
        CardProposal(observationKey: observation.id, title: title, meaning: "Avery is waiting on a delivery date from you.",
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
