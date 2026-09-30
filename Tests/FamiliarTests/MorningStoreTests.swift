import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct MorningStoreTests {
    @Test func firstLaunchCreatesPrivateEmptyWorkspaceAndRetainsFolderIDs() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        #expect(store.error == nil)
        #expect(store.cards.isEmpty && store.people.isEmpty && store.workItems.isEmpty)
        #expect(!store.workspace.samplesLoaded)
        #expect(store.folders.map(\.name) == ["Replies", "Unfinished", "Housekeeping"])
        let reopened = MorningStore(directory: fixture.directory)
        #expect(reopened.workspace == store.workspace)
        let folderMode = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: fixture.database.path)[.posixPermissions] as? NSNumber
        #expect(folderMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func peopleFilesEvidenceAndDecisionsSurviveRelaunch() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let folder = MorningFolder(name: "Customers")
        let person = MorningPerson(name: "Avery", role: "Customer", relationship: "Rollout owner", context: "Waiting for our date", identities: ["avery@example.com", "jira:avery"])
        try store.saveFolder(folder)
        try store.savePerson(person)
        let card = fixture.card(folderID: folder.id, people: [person.id])
        try store.saveCard(card)
        try store.setDisposition(cardID: card.id, to: .mine)
        let reopened = MorningStore(directory: fixture.directory)
        #expect(reopened.workspace == store.workspace)
        #expect(reopened.cards.first?.sources.first?.excerpt == "We promised an update. The date is not confirmed.")
        #expect(reopened.cards.first?.disposition == .mine)
        #expect(reopened.people.first?.identities == ["avery@example.com", "jira:avery"])
    }

    @Test func selectingMeDemotesPreviousIdentityWithoutLosingPeople() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let original = MorningPerson(name: "Original", isMe: true)
        let replacement = MorningPerson(name: "Replacement", isMe: true)
        try store.savePerson(original)
        try store.savePerson(replacement)
        #expect(store.people.count == 2)
        #expect(store.people.filter(\.isMe).map(\.id) == [replacement.id])
        #expect(MorningStore(directory: fixture.directory).people.filter(\.isMe).map(\.id) == [replacement.id])
    }

    @Test func invalidReferencesAndEmptyInstructionsCannotEnterStorage() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let baseline = store.workspace
        #expect(throws: MorningStoreError.self) { try store.savePerson(MorningPerson(name: "  \n")) }
        #expect(throws: MorningStoreError.self) { try store.saveFolder(MorningFolder(name: "")) }
        #expect(throws: MorningStoreError.self) { try store.saveCard(fixture.card(folderID: UUID())) }
        #expect(throws: MorningStoreError.self) { try store.saveCard(fixture.card(folderID: store.folders[0].id, people: [UUID()])) }
        var card = fixture.card(folderID: store.folders[0].id)
        card.action.instruction = "  "
        #expect(throws: MorningStoreError.self) { try store.saveCard(card) }
        #expect(store.workspace == baseline)
        #expect(MorningStore(directory: fixture.directory).workspace == baseline)
    }

    @Test func enqueueCommitsDecisionAndImmutableActionPeopleEvidenceTogether() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        var person = MorningPerson(name: "Avery", relationship: "Customer", context: "Waiting for a date")
        try store.savePerson(person)
        var card = fixture.card(folderID: store.folders[0].id, people: [person.id])
        try store.saveCard(card)
        let original = try #require(store.cards.first)
        let accepted = try store.enqueue(cardID: card.id)
        #expect(accepted.card == original)
        #expect(accepted.people == [person])
        #expect(accepted.action == card.action)
        #expect(store.cards.first?.disposition == .delegated)
        let saved = MorningStore(directory: fixture.directory)
        #expect(saved.workItems == [accepted])
        #expect(saved.cards.first?.disposition == .delegated)

        person.context = "New relationship information"
        card.action.instruction = "A different proposed action"
        card.sources[0].excerpt = "New evidence"
        card.disposition = .ignored
        try store.savePerson(person)
        try store.saveCard(card)
        #expect(store.workItems == [accepted])
        #expect(store.cards.first?.action.instruction == "A different proposed action")
        #expect(store.cards.first?.disposition == .delegated)
        #expect(store.people.first?.context == "New relationship information")
    }

    @Test func pendingCardCannotBeQueuedTwiceOrSilentlyRefiled() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let card = fixture.card(folderID: store.folders[0].id)
        try store.saveCard(card)
        _ = try store.enqueue(cardID: card.id)
        #expect(throws: MorningStoreError.self) { try store.enqueue(cardID: card.id) }
        #expect(throws: MorningStoreError.self) { try store.enqueue(cardID: card.id, kind: .context) }
        #expect(throws: MorningStoreError.self) { try store.setDisposition(cardID: card.id, to: .ignored) }
        #expect(throws: MorningStoreError.self) { try store.returnToFolder(cardID: card.id) }
        #expect(store.workItems.count == 1)
        #expect(store.cards.first?.disposition == .delegated)
    }

    @Test func acceptedWorkIncludesYourOwnRoleEvenWhenNotExplicitlyLinked() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        var me = MorningPerson(name: "You", role: "Delivery owner", context: "Responsible for Atlas launch readiness", isMe: true)
        let customer = MorningPerson(name: "Avery", relationship: "Customer rollout lead")
        try store.savePerson(me)
        try store.savePerson(customer)
        let card = fixture.card(folderID: store.folders[0].id, people: [customer.id])
        try store.saveCard(card)
        let accepted = try store.enqueue(cardID: card.id)
        #expect(accepted.people == [customer, me])
        me.role = "A different current role"
        try store.savePerson(me)
        #expect(store.workItems.first?.people.last?.role == "Delivery owner")
        #expect(MorningStore(directory: fixture.directory).workItems.first?.people == accepted.people)

        let selfLinked = fixture.card(folderID: store.folders[0].id, people: [me.id])
        try store.saveCard(selfLinked)
        let second = try store.enqueue(cardID: selfLinked.id)
        #expect(second.people == [me])
    }

    @Test func unrelatedPeopleCannotBeSmuggledIntoAnAcceptedSnapshot() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let card = fixture.card(folderID: store.folders[0].id)
        try store.saveCard(card)
        _ = try store.enqueue(cardID: card.id)
        var corrupted = store.workspace
        corrupted.workItems[0].people = [MorningPerson(name: "Unrelated person")]
        try SQLiteMorningRepository(directory: fixture.directory).save(corrupted)
        let original = try Data(contentsOf: fixture.database)
        let reopened = MorningStore(directory: fixture.directory)
        #expect(reopened.error != nil)
        #expect(throws: MorningStoreError.self) { try reopened.loadSamples() }
        #expect(try Data(contentsOf: fixture.database) == original)
    }

    @Test func contextResultLeavesOriginalDecisionOpenAndAllowsLaterAction() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let card = fixture.card(folderID: store.folders[0].id)
        try store.saveCard(card)
        let investigation = try store.enqueue(cardID: card.id, kind: .context)
        #expect(investigation.action == card.contextAction)
        #expect(store.cards.first?.disposition == .unreviewed)
        try store.updateWork(id: investigation.id, status: .running)
        try store.updateWork(id: investigation.id, status: .completed, result: "The source still has no confirmed date.")
        #expect(store.cards.first?.disposition == .unreviewed)
        #expect(store.workItems.first?.result == "The source still has no confirmed date.")
        let action = try store.enqueue(cardID: card.id)
        #expect(store.cards.first?.disposition == .delegated)
        try store.updateWork(id: action.id, status: .completed, result: "Draft prepared.")
        #expect(store.cards.first?.disposition == .completed)
        #expect(store.workItems.count == 2)
    }

    @Test func contextFailurePreservesPersonalOwnership() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let card = fixture.card(folderID: store.folders[0].id)
        try store.saveCard(card)
        try store.setDisposition(cardID: card.id, to: .mine)
        let investigation = try store.enqueue(cardID: card.id, kind: .context)
        try store.updateWork(id: investigation.id, status: .failed, result: "Could not retrieve the evidence.")
        #expect(store.cards.first?.disposition == .mine)
    }

    @Test func restartInterruptsStartedWorkButPreservesWaitingWorkWithoutReplay() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        var jobs: [MorningWorkItem] = []
        for index in 0..<3 {
            let card = fixture.card(folderID: store.folders[0].id, title: "Work \(index)")
            try store.saveCard(card)
            jobs.append(try store.enqueue(cardID: card.id))
        }
        try store.updateWork(id: jobs[0].id, status: .running, progress: "Preparing")
        try store.updateWork(id: jobs[1].id, status: .needsAttention, progress: "Waiting for approval")
        let reopened = MorningStore(directory: fixture.directory)
        #expect(reopened.error == nil)
        #expect(reopened.workItems.map(\.status) == [.interrupted, .interrupted, .queued])
        #expect(reopened.cards.map(\.disposition) == [.unreviewed, .unreviewed, .delegated])
        #expect(reopened.workItems[0].finishedAt != nil)
        #expect(reopened.workItems[0].progress.contains("Check what happened"))
        #expect(MorningStore(directory: fixture.directory).workspace == reopened.workspace)
        #expect(throws: MorningStoreError.self) { try reopened.updateWork(id: jobs[0].id, status: .running) }
    }

    @Test func failureAndQueuedCancellationReturnWorkToItsOwner() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let first = fixture.card(folderID: store.folders[0].id)
        let second = fixture.card(folderID: store.folders[0].id)
        try store.saveCard(first)
        try store.saveCard(second)
        try store.setDisposition(cardID: second.id, to: .mine)
        let failed = try store.enqueue(cardID: first.id)
        let cancelled = try store.enqueue(cardID: second.id)
        try store.updateWork(id: failed.id, status: .running)
        #expect(throws: MorningStoreError.self) { try store.cancelQueued(id: failed.id) }
        try store.updateWork(id: failed.id, status: .failed, result: "No connection.")
        try store.cancelQueued(id: cancelled.id)
        #expect(store.cards.map(\.disposition) == [.unreviewed, .mine])
        #expect(store.workItems.map(\.status) == [.failed, .cancelled])
        #expect(store.workItems[0].result == "No connection.")
    }

    @Test func lateTerminalMetadataCannotUndoNewDecision() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let card = fixture.card(folderID: store.folders[0].id)
        try store.saveCard(card)
        let first = try store.enqueue(cardID: card.id)
        try store.updateWork(id: first.id, status: .failed)
        try store.setDisposition(cardID: card.id, to: .ignored)
        try store.updateWork(id: first.id, status: .failed, progress: "Late failure detail")
        #expect(store.cards.first?.disposition == .ignored)
    }

    @Test func corruptFileRemainsUntouchedAndBlocksAllWrites() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let original = Data("{not valid JSON".utf8)
        try original.write(to: fixture.file)
        let store = MorningStore(directory: fixture.directory)
        #expect(store.error != nil)
        #expect(throws: MorningStoreError.self) { try store.savePerson(MorningPerson(name: "Avery")) }
        #expect(throws: MorningStoreError.self) { try store.loadSamples() }
        #expect(try Data(contentsOf: fixture.file) == original)
        #expect(store.people.isEmpty && store.cards.isEmpty)
    }

    @Test func futureFormatRemainsUntouchedRatherThanBeingResetToEmpty() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let original = Data(#"{"version":42,"futureData":"keep this"}"#.utf8)
        try original.write(to: fixture.file)
        let store = MorningStore(directory: fixture.directory)
        #expect(store.error?.contains("version 42") == true)
        #expect(throws: MorningStoreError.self) { try store.saveFolder(MorningFolder(name: "New")) }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test func structurallyInvalidSavedReferencesAreProtected() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        var workspace = MorningWorkspace()
        workspace.cards = [fixture.card(folderID: UUID())]
        let original = try JSONEncoder().encode(workspace)
        try original.write(to: fixture.file)
        let store = MorningStore(directory: fixture.directory)
        #expect(store.error != nil)
        #expect(throws: MorningStoreError.self) { try store.loadSamples() }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test func failedHandoffWritePublishesNeitherQueueItemNorDelegatedDecision() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let card = fixture.card(folderID: store.folders[0].id)
        try store.saveCard(card)
        let before = store.workspace
        let backup = fixture.directory.appendingPathComponent("backup.sqlite")
        try FileManager.default.moveItem(at: fixture.database, to: backup)
        try FileManager.default.createDirectory(at: fixture.database, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.enqueue(cardID: card.id) }
        #expect(store.workspace == before)
        #expect(store.error != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!leftovers.contains(where: { $0.hasPrefix(".morning-") }))
        try FileManager.default.removeItem(at: fixture.database)
        try FileManager.default.moveItem(at: backup, to: fixture.database)
        #expect(MorningStore(directory: fixture.directory).workspace == before)
        _ = try store.enqueue(cardID: card.id)
        #expect(store.error == nil)
        #expect(store.workItems.count == 1)
    }

    @Test func explicitSampleLoadingPreservesRealDataAndIsIdempotentAcrossRelaunch() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        let person = MorningPerson(name: "Maya Chen", context: "A real contact", isMe: true)
        try store.savePerson(person)
        let card = fixture.card(folderID: store.folders[0].id, people: [person.id])
        try store.saveCard(card)
        let original = try #require(store.cards.first)
        try store.loadSamples()
        #expect(store.workspace.samplesLoaded)
        #expect(store.cards.filter(\.isSample).count == 5)
        #expect(store.cards.first(where: { $0.id == card.id }) == original)
        #expect(store.people.first(where: { $0.id == person.id }) == person)
        #expect(store.people.filter(\.isMe).map(\.id) == [person.id])
        #expect(store.workItems.isEmpty)
        let seeded = store.workspace
        try store.loadSamples()
        #expect(store.workspace == seeded)
        let reopened = MorningStore(directory: fixture.directory)
        try reopened.loadSamples()
        #expect(reopened.workspace == seeded)
        #expect(reopened.cards.filter(\.isSample).allSatisfy { card in
            card.action.mode == .prepare && card.contextAction?.mode == .prepare && card.sources.allSatisfy { $0.kind.contains("fictional sample") }
        })
    }

    @Test func sampleProvenanceCannotBeChangedToPermitDesktopActions() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        try store.loadSamples()
        var sample = try #require(store.cards.first)
        sample.isSample = false
        sample.action.mode = .desktop
        #expect(throws: MorningStoreError.self) { try store.saveCard(sample) }
        #expect(store.cards.first?.isSample == true)
        #expect(store.cards.first?.action.mode == .prepare)
        var newSample = fixture.card(folderID: store.folders[0].id)
        newSample.isSample = true
        newSample.contextAction?.mode = .desktop
        #expect(throws: MorningStoreError.self) { try store.saveCard(newSample) }
    }

    @Test func choosingAnotherOptionMakesItTheCardsActionBeforeItRuns() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        var card = fixture.card(folderID: store.folders[0].id)
        let ask = MorningAction(title: "Ask for the date", instruction: "Draft a question asking for the date.")
        let hold = MorningAction(title: "Draft a holding note", instruction: "Draft a short holding note.")
        card.alternatives = [ask, hold]
        try store.saveCard(card)
        let primary = card.action

        let item = try store.enqueue(cardID: card.id, optionID: hold.id)

        #expect(item.action == hold && item.card.action == hold)
        #expect(store.cards[0].action == hold)
        #expect(store.cards[0].alternatives == [ask, primary])
        #expect(store.cards[0].disposition == .delegated)
        #expect(MorningStore(directory: fixture.directory).workItems == store.workItems)   // the snapshot still validates
        try store.updateWork(id: item.id, status: .completed, result: "Drafted.")
        #expect(throws: MorningStoreError.self) { try store.enqueue(cardID: card.id, optionID: UUID()) }
        #expect(throws: MorningStoreError.self) { try store.enqueue(cardID: card.id, kind: .context, optionID: ask.id) }
    }

    @Test func anOptionCountsAsRunOnlyOnceWorkOnItStarted() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        var card = fixture.card(folderID: store.folders[0].id)
        let ask = MorningAction(title: "Ask for the date", instruction: "Draft a question asking for the date.")
        card.alternatives = [ask]
        try store.saveCard(card)

        let removed = try store.enqueue(cardID: card.id, optionID: ask.id)
        try store.cancelQueued(id: removed.id)   // taken off the queue before it started
        #expect(!MorningFilesView.hasRun(ask, in: store.workItems))

        let item = try store.enqueue(cardID: card.id, optionID: ask.id)
        try store.updateWork(id: item.id, status: .running)
        try store.updateWork(id: item.id, status: .completed, result: "Drafted.")
        #expect(MorningFilesView.hasRun(ask, in: store.workItems))
        #expect(!MorningFilesView.hasRun(card.action, in: store.workItems))
    }

    @Test func extraOptionsAreCheckedLikeTheAction() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = MorningStore(directory: fixture.directory)
        var card = fixture.card(folderID: store.folders[0].id)
        let fine = MorningAction(title: "Ask", instruction: "Draft a question.")
        card.alternatives = [MorningAction(title: "Empty", instruction: " ")]
        #expect(throws: MorningStoreError.self) { try store.saveCard(card) }
        card.alternatives = [fine, fine, MorningAction(title: "Third", instruction: "Draft.")]
        #expect(throws: MorningStoreError.self) { try store.saveCard(card) }   // at most three options in all
        var duplicate = card.action; duplicate.title = "Same id"
        card.alternatives = [duplicate]
        #expect(throws: MorningStoreError.self) { try store.saveCard(card) }
        card.alternatives = [fine]
        try store.saveCard(card)
        #expect(store.cards[0].options.count == 2)
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-morning-tests-\(UUID().uuidString)")
        var file: URL { directory.appendingPathComponent("workspace.json") }
        var database: URL { directory.appendingPathComponent("morning.sqlite") }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func card(folderID: UUID, people: [UUID] = [], title: String = "Confirm rollout date") -> MorningCard {
            MorningCard(folderID: folderID, title: title, summary: "A customer is waiting.", personIDs: people,
                        sources: [MorningSource(title: "Rollout note", excerpt: "We promised an update. The date is not confirmed.")],
                        rationale: "We promised to follow up.",
                        action: MorningAction(title: "Prepare reply", instruction: "Draft an update without promising a date."),
                        contextAction: MorningAction(title: "Find missing context", instruction: "Identify the unanswered questions in the note."),
                        unknowns: "Confirmed date")
        }
    }
}
