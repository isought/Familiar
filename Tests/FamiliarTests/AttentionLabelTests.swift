import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

/// What the person already does to a card counts once as a guessed label, from the card or from chat; work, evidence,
/// new cards, samples and notes never do. A thumb beats a guess, clear goes back to it, and an explanation never
/// flips it. Labels live only in the ledger: never on the card, in chat, in runs or in noteling.log.
@Suite @MainActor
struct AttentionLabelTests {
    @Test func eachExistingActionCountsOnce() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store, id = fixture.cardID
        let second = store.cards[0].options[1]

        let tapped = try fixture.signals { try store.enqueue(cardID: id, optionID: second.id) }
        #expect(tapped.map(\.signal) == [.optionTapped] && tapped[0].optionIndex == 1 && tapped[0].optionMode == .prepare)
        #expect(store.cards[0].action.id == second.id)   // the store moved it to the front; its place is read from before
        #expect(tapped[0].key == fixture.key && tapped[0].card.cardID == id && tapped[0].card.disposition == .delegated)
        // A card from before the ledger, from a source it reads, carries its item as the card knows it, without mail facts.
        #expect(tapped[0].item.subject == "Lease renewal: sign by Friday" && tapped[0].item.shown && tapped[0].item.from == nil)
        #expect(tapped[0].item.preview == "Please sign the renewal by Friday." && tapped[0].item.url == "https://mail.example.test/lease")
        try store.cancelQueued(id: store.workItems[0].id)

        let context = try fixture.signals { try store.enqueue(cardID: id, kind: .context) }
        #expect(context.map(\.signal) == [.contextRequested] && context[0].optionIndex == nil)
        try store.updateWork(id: store.workItems[1].id, status: .completed)

        #expect(try fixture.signals { try store.setDisposition(cardID: id, to: .mine) }.map(\.signal) == [.mine])
        #expect(try fixture.signals { try store.setDisposition(cardID: id, to: .ignored) }.map(\.signal) == [.ignored])
        #expect(try fixture.signals { try store.setCardResolution(cardID: id, resolved: true) }.map(\.signal) == [.handled])
        var edited = store.cards[0]
        edited.title = "Sign the lease before Friday"
        #expect(try fixture.signals { try store.saveCard(edited) }.map(\.signal) == [.adjusted])
        #expect(try fixture.signals { try store.updateCardContext(cardID: id, context: "Dana prefers email") }.map(\.signal) == [.adjusted])
        #expect(fixture.implicit.count == 7 && fixture.labels.isEmpty)
    }

    @Test func chatToolsCountToo() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let conversation = CardConversation(store: fixture.store)
        conversation.select(fixture.cardID)
        let router = try ToolRouter(routes: conversation.routes())

        let queued = await router.execute("queue_card_action", ["option": "Open the lease portal"], toolset: nil)
        #expect(!queued.isError && fixture.implicit.map(\.signal) == [.optionTapped])
        #expect(fixture.implicit.last?.optionIndex == 2 && fixture.implicit.last?.optionMode == .desktop)

        // Marking it handled cancels the queued work; only the person's word counts.
        let handled = await router.execute("set_card_handled", ["handled": true], toolset: nil)
        let adjusted = await router.execute("update_card_context", ["context": "Dana prefers email"], toolset: nil)
        #expect(!handled.isError && !adjusted.isError && fixture.store.workItems.first?.status == .cancelled)
        #expect(fixture.implicit.map(\.signal) == [.optionTapped, .handled, .adjusted])
        #expect(fixture.ledger.effective(for: fixture.key).state == .guessYes)
    }

    @Test func automaticChangesAreNotSignals() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store, id = fixture.cardID

        // Work ends on its own and moves the card out of With Noteling, back to the decision it had: done, failed, or
        // removed from the queue, from a card to review and from one kept for later.
        for kept in [false, true] {
            if kept { try store.setDisposition(cardID: id, to: .mine) }
            for end in [MorningWorkStatus.completed, .failed] {
                let item = try store.enqueue(cardID: id)
                try store.updateWork(id: item.id, status: .running)
                try store.updateWork(id: item.id, status: end)
            }
            try store.cancelQueued(id: try store.enqueue(cardID: id).id)
            #expect(store.cards[0].disposition == (kept ? .mine : .unreviewed))
        }

        // A card step makes a card, updates it, then evidence resolves it and cancels its queued work.
        let observation = CardObservation(runID: UUID(), sourceID: fixture.sourceID, itemKey: "parcel@shop.example.test", sourceName: "Example Gmail",
            kind: "mail", title: "Your parcel is delayed", excerpt: "It now arrives Monday.", url: "", identityEvidence: "Message-ID",
            observedAt: Date(), state: .open, stateEvidence: "No delivery yet")
        let proposal = CardProposal(observationKey: observation.id, title: "Your parcel is late", meaning: "It arrives Monday.",
            action: MorningAction(title: "Ask for a refund", instruction: "Draft a refund request."))
        try store.applyCardGeneration(observations: [observation], proposals: [proposal], runIDs: [observation.runID])
        var changed = observation
        changed.runID = UUID(); changed.observedAt = observation.observedAt.addingTimeInterval(60); changed.excerpt = "It now arrives Tuesday."
        var revised = proposal
        revised.meaning = "It arrives Tuesday."
        try store.applyCardGeneration(observations: [changed], proposals: [revised], runIDs: [changed.runID])
        let parcel = try #require(store.cards.first { $0.tracking?.key == observation.id })
        try store.enqueue(cardID: parcel.id)
        var delivered = changed
        delivered.runID = UUID(); delivered.observedAt = changed.observedAt.addingTimeInterval(60)
        delivered.state = .resolved; delivered.stateEvidence = "Delivered today"
        try store.applyCardGeneration(observations: [delivered], proposals: [], runIDs: [delivered.runID])
        #expect(store.cards.first { $0.id == parcel.id }?.isResolved == true && store.workItems.last?.status == .cancelled)
        // Reopening what evidence resolved takes back nothing the person said.
        try store.setCardResolution(cardID: parcel.id, resolved: false)

        // Samples and hand-written notes are not part of the test.
        try store.loadSamples()
        var note = MorningCard(folderID: store.folders[0].id, title: "Call the plumber",
            action: MorningAction(title: "Find the number", instruction: "Find the plumber's number."))
        try store.saveCard(note)
        note.title = "Call the plumber today"
        try store.saveCard(note)
        try store.setDisposition(cardID: note.id, to: .ignored)
        let sample = try #require(store.cards.first { $0.isSample })
        try store.setDisposition(cardID: sample.id, to: .mine)

        // Only the taps that handed work over, and keeping the card.
        let taps = Array(repeating: AttentionSignal.optionTapped, count: 3)
        #expect(fixture.implicit.map(\.signal) == taps + [.mine] + taps + [.optionTapped])
        #expect(fixture.ledger.effective(for: observation.id).state == .guessYes)
    }

    @Test func undoAndReturnRetract() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store, ledger = fixture.ledger, id = fixture.cardID, key = fixture.key

        // Ignore, then Undo: the card goes back to the decision it had.
        try store.setDisposition(cardID: id, to: .ignored)
        let undo = try fixture.signals { try store.setDisposition(cardID: id, to: .unreviewed) }
        #expect(undo.map(\.signal) == [.retract] && undo[0].retracts == .ignored)
        #expect(ledger.effective(for: key).state == .notSet && ledger.effective(for: key).guess == nil)

        // I'll do it, Ignore, then Undo back to I'll do it.
        try store.setDisposition(cardID: id, to: .mine)
        try store.setDisposition(cardID: id, to: .ignored)
        #expect(ledger.effective(for: key).state == .guessNo)
        try store.setDisposition(cardID: id, to: .mine)
        #expect(ledger.effective(for: key).state == .guessYes && ledger.effective(for: key).guess == .mine)

        let returned = try fixture.signals { try store.returnToFolder(cardID: id) }
        #expect(returned.map(\.signal) == [.retract] && returned[0].retracts == .mine)
        #expect(ledger.effective(for: key).state == .notSet)   // the Undo replaced the Ignore, so nothing is left

        try store.setCardResolution(cardID: id, resolved: true)
        let reopened = try fixture.signals { try store.setCardResolution(cardID: id, resolved: false) }
        #expect(reopened.map(\.signal) == [.retract] && reopened[0].retracts == .handled)
        #expect(ledger.effective(for: key).state == .notSet)
    }

    @Test func effectiveLabelPrecedence() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store, ledger = fixture.ledger, id = fixture.cardID, key = fixture.key

        try store.setDisposition(cardID: id, to: .ignored)
        ledger.label(key: key, card: nil, value: .yes, via: .card)
        #expect(ledger.effective(for: key).state == .yes && !ledger.effective(for: key).isGuessed)

        ledger.label(key: key, card: nil, value: .strongYes, via: .card)
        try store.setDisposition(cardID: id, to: .unreviewed)
        try store.setDisposition(cardID: id, to: .ignored)   // a later Ignore
        #expect(ledger.effective(for: key).state == .strongYes && ledger.effective(for: key).isYes == true)

        ledger.label(key: key, card: nil, value: .clear, via: .card)
        #expect(ledger.effective(for: key).state == .guessNo && ledger.effective(for: key).guess == .ignored)

        ledger.explain(key: key, card: nil, text: "  Only Dana's letters matter.  ", via: .card)
        #expect(ledger.effective(for: key).state == .guessNo && ledger.explanation(for: key) == "Only Dana's letters matter.")
        ledger.label(key: key, card: nil, value: .no, via: .card)
        ledger.explain(key: key, card: nil, text: "It was already signed.", via: .card)
        #expect(ledger.effective(for: key).state == .no && ledger.explanation(for: key) == "It was already signed.")

        // The file says the same after a restart.
        #expect(fixture.reopened().effective(for: key) == ledger.effective(for: key))
    }

    @Test func thumbCycle() {
        let next = AttentionLabels.next
        #expect(next(nil, .up) == .yes && next(.yes, .up) == .strongYes && next(.strongYes, .up) == .clear)
        #expect(next(nil, .down) == .no && next(.no, .down) == .strongNo && next(.strongNo, .down) == .clear)
        #expect(next(.yes, .down) == .no && next(.strongYes, .down) == .no)
        #expect(next(.no, .up) == .yes && next(.strongNo, .up) == .yes)
    }

    @Test func priorAndWeightAreRecorded() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store, ledger = fixture.ledger, key = fixture.key
        try store.setDisposition(cardID: fixture.cardID, to: .ignored)

        ledger.tapThumb(key: key, card: store.cards[0], thumb: .up, via: .card)
        ledger.tapThumb(key: key, card: store.cards[0], thumb: .up, via: .shown)
        let labels = fixture.labels
        #expect(labels.map(\.value) == [.yes, .strongYes] && labels.map(\.weight) == [1, 2] && labels.map(\.prior) == [.guessNo, .yes])
        #expect(labels.map(\.via) == [.card, .shown] && labels.allSatisfy { $0.key == key && $0.item.key == key && $0.text == nil })
        #expect(labels[0].card?.cardID == fixture.cardID && labels[0].card?.disposition == .ignored && labels[0].card?.optionCount == 3)
        #expect(labels[0].card?.optionModes == [.prepare, .prepare, .desktop] && labels[0].card?.createdByRun == fixture.runID)
    }

    @Test func labelsNeverTouchTheCard() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store, ledger = fixture.ledger, key = fixture.key
        let saves = fixture.repository.saves, before = store.workspace

        for thumb in [AttentionLabels.Thumb.up, .up, .down, .down, .down] {
            ledger.tapThumb(key: key, card: store.cards[0], thumb: thumb, via: .card)
        }
        ledger.beginExplaining(key)
        #expect(ledger.explaining == key)
        ledger.explain(key: key, card: store.cards[0], text: "The rent goes up if I miss it.", via: .card)

        #expect(fixture.labels.map(\.value) == [.yes, .strongYes, .no, .strongNo, .clear, .explain])
        #expect(fixture.labels.map(\.weight) == [1, 2, -1, -2, 0, 0] && fixture.labels.last?.text == "The rent goes up if I miss it.")
        #expect(ledger.explaining == nil && ledger.effective(for: key).state == .notSet)
        #expect(fixture.repository.saves == saves && store.workspace == before && store.cards[0].disposition == .unreviewed)
        #expect(fixture.implicit.isEmpty && store.workItems.isEmpty)
    }

    @Test func explanationsAreCappedAndSavedOnlyWhenTheyChange() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger, key = fixture.key
        ledger.explain(key: key, card: nil, text: String(repeating: "a", count: 2_500), via: .card)
        #expect(ledger.explanation(for: key)?.count == AttentionLabels.explanationLimit)
        ledger.explain(key: key, card: nil, text: String(repeating: "a", count: 2_100), via: .card)   // the same once capped
        ledger.beginExplaining(key)
        ledger.cancelExplaining()
        #expect(fixture.labels.count == 1 && ledger.explaining == nil)
        ledger.explain(key: key, card: nil, text: " ", via: .card)
        #expect(fixture.labels.count == 2 && ledger.explanation(for: key) == nil)
        // A cut that ends on a space is saved as the index keeps it, so saving the same words again writes nothing.
        let spaced = String(repeating: "b", count: AttentionLabels.explanationLimit - 1) + " and more"
        ledger.explain(key: key, card: nil, text: spaced, via: .card)
        ledger.explain(key: key, card: nil, text: spaced, via: .card)
        #expect(fixture.labels.count == 3 && ledger.explanation(for: key)?.count == AttentionLabels.explanationLimit - 1)
        #expect(fixture.labels.last?.text == ledger.explanation(for: key))
    }

    @Test func aGuessWhoseWriteFailedIsWrittenWithTheNextWrite() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store, ledger = fixture.ledger
        // The disk refuses the write just as the person chooses "I'll do it".
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.file.path)
        try store.setDisposition(cardID: fixture.cardID, to: .mine)
        #expect(fixture.implicit.isEmpty)
        #expect(ledger.error == "Couldn’t save the attention test in Noteling’s attention folder (error \(EACCES)). Your cards aren’t affected.")
        #expect(ledger.pending.map(\.type) == [.implicit] && ledger.effective(for: fixture.key).state == .notSet)
        // Opening another card while it still fails keeps the error, and both wait.
        ledger.cardOpened(store.cards[0])
        #expect(ledger.error != nil && ledger.pending.map(\.type) == [.implicit, .engaged])

        // The next write that goes through, however unrelated, writes them first, in order, and only then clears the error.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        ledger.cardOpened(store.cards[0])
        #expect(fixture.events.suffix(3).map(\.type) == [.implicit, .engaged, .engaged])
        #expect(fixture.implicit.map(\.signal) == [.mine] && fixture.implicit.first?.key == fixture.key)
        #expect(ledger.effective(for: fixture.key).state == .guessYes && ledger.error == nil && ledger.pending.isEmpty)
        #expect(fixture.reopened().effective(for: fixture.key).state == .guessYes)
    }

    @Test func tappingAgainAfterAFailedWriteOnlyTriesItAgain() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger, key = fixture.key
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.file.path)
        ledger.tapThumb(key: key, card: nil, thumb: .up, via: .card)
        // The thumb did not change, so the person taps it again.
        ledger.tapThumb(key: key, card: nil, thumb: .up, via: .card)
        #expect(ledger.pending.count == 1 && ledger.effective(for: key).state == .notSet && ledger.error != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        ledger.tapThumb(key: key, card: nil, thumb: .up, via: .card)
        #expect(fixture.labels.map(\.value) == [.yes] && ledger.effective(for: key).state == .yes && ledger.error == nil)

        // A thumb that could not be written never took effect: the card still shows yes. Another tap takes its place,
        // so the file never holds the no the person replaced, and the strong yes follows the yes they saw.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.file.path)
        ledger.tapThumb(key: key, card: nil, thumb: .down, via: .card)
        ledger.tapThumb(key: key, card: nil, thumb: .up, via: .card)
        #expect(ledger.pending.count == 1 && ledger.effective(for: key).state == .yes)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        ledger.tapThumb(key: key, card: nil, thumb: .up, via: .card)
        #expect(fixture.labels.map(\.value) == [.yes, .strongYes] && fixture.labels.map(\.prior) == [.notSet, .yes])
        #expect(ledger.effective(for: key).state == .strongYes && ledger.pending.isEmpty && ledger.error == nil)
    }

    @Test func wordsWhoseSaveFailedAreNeverWrittenOnceThePersonMovesOn() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let card = fixture.store.cards[0], ledger = fixture.ledger, key = fixture.key
        // The disk refuses a thumb, then the words the person saves. The thumb waits; the words stay in the field.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.file.path)
        ledger.tapThumb(key: key, card: card, thumb: .up, via: .card)
        ledger.beginExplaining(key)
        ledger.explain(key: key, card: card, text: "Pat Quill never renews on time.", via: .card)
        #expect(ledger.explaining == key && ledger.error != nil && ledger.pending.map(\.type) == [.label])
        // A write that goes through while the field is open writes the thumb, never words the person may still change.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        ledger.cardOpened(card)
        #expect(fixture.labels.map(\.value) == [.yes] && ledger.explaining == key && ledger.explanation(for: key) == nil)

        // Cancelled after a failed save, the words are dropped.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.file.path)
        ledger.explain(key: key, card: card, text: "Pat Quill never renews on time.", via: .card)
        ledger.cancelExplaining()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        ledger.cardOpened(card)
        #expect(fixture.labels.map(\.value) == [.yes] && ledger.error == nil && ledger.pending.isEmpty)

        // Rewritten after a failed save, only the words saved are kept.
        ledger.beginExplaining(key)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.file.path)
        ledger.explain(key: key, card: card, text: "Pat Quill never renews on time.", via: .card)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        ledger.explain(key: key, card: card, text: "The landlord never renews on time.", via: .card)
        #expect(fixture.labels.compactMap(\.text) == ["The landlord never renews on time."] && ledger.explaining == nil)
        #expect(try !String(contentsOf: fixture.file, encoding: .utf8).contains("Pat Quill"))
    }

    @Test func onlySourcesTheTestReadsKeepTheirWords() throws {
        // A card from a source the test never read, such as a calendar or a screen read, is labeled by which item it
        // was, never by what it said. Its key can be made of the item's own words, so it is recorded by a digest of it.
        let fixture = Fixture(read: false)
        defer { fixture.remove() }
        try fixture.store.setDisposition(cardID: fixture.cardID, to: .mine)
        fixture.ledger.tapThumb(key: fixture.key, card: nil, thumb: .up, via: .card)
        let items = fixture.implicit.map(\.item) + fixture.labels.map(\.item)
        #expect(items.count == 2 && items.allSatisfy { $0.subject.isEmpty && $0.preview.isEmpty && $0.url == nil })
        let digest = try #require(items.first?.key)
        #expect(digest == CardObservation.key(sourceID: fixture.sourceID, itemKey: items[0].itemID) && items[0].itemID.count == 64)
        #expect(items.allSatisfy { $0.key == digest && $0.itemID == items[0].itemID && $0.kind == "mail" && $0.shown })
        #expect(fixture.implicit.map(\.key) + fixture.labels.map(\.key) == [digest, digest])
        let written = String(decoding: try Data(contentsOf: fixture.file), as: UTF8.self)
        #expect(!written.contains("Lease renewal") && !written.contains("Please sign") && !written.contains("signed lease")
            && !written.contains("mail.example.test/lease") && !written.contains("lease@rent.example.test"))
        #expect(fixture.ledger.effective(for: digest).state == .yes && fixture.ledger.index.labels[fixture.key] == nil)
    }

    @Test func theLedgerNeverLeavesTheMac() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-private-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
        let job = LearnedReadingSource(kind: .mail, name: "Example Gmail", meaning: "My personal inbox",
            scope: "Show anything that needs a reply", script: "imap-mail__today")
        try sources.saveReadingSource(job)
        let rows: [[String: Any]] = ["lease", "sale", "news"].map { name in
            ["key": "\(name)@example.test", "title": "About the \(name)", "from": "Dana <dana@example.test>", "tab": "primary",
             "bulk": name != "lease", "preview": "More about the \(name)."]
        }
        try sources.saveReadingSnapshot(try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": 3, "items": rows],
            request: ReadingReadRequest(source: job), collectedAt: Date()))
        let store = MorningStore(directory: root.appendingPathComponent("morning"))
        let ledger = AttentionLedger(directory: root.appendingPathComponent("attention"), timeZone: TimeZone(identifier: "America/New_York")!)
        ledger.watch(store)
        let input = CardGenerationInput.saved(in: sources, runID: nil, excluding: [])
        let shown = input.observations[0], rest = input.observations[1]
        try store.applyCardGeneration(observations: input.observations, proposals: [CardProposal(observationKey: shown.id,
            title: "Dana needs the signed lease", meaning: "The renewal lapses Friday.",
            action: MorningAction(title: "Draft a reply", instruction: "Draft a short reply to Dana."))], runIDs: input.runIDs)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: sources.runStore, cards: store.cards)
        let card = store.cards[0]

        try store.setDisposition(cardID: card.id, to: .mine)
        ledger.tapThumb(key: shown.id, card: card, thumb: .up, via: .card)
        ledger.explain(key: shown.id, card: card, text: "PRIVATE-EXPLAIN-TEXT-7", via: .card)
        ledger.miss(key: rest.id)
        let written = String(decoding: try Data(contentsOf: root.appendingPathComponent("attention/signals.jsonl")), as: UTF8.self)
        #expect(written.contains("PRIVATE-EXPLAIN-TEXT-7") && ledger.index.missedKeys == [rest.id])
        #expect(ledger.effective(for: shown.id).state == .yes && ledger.error == nil)

        func isPrivate(_ text: String) -> Bool { !text.contains("PRIVATE-EXPLAIN-TEXT-7") && !text.lowercased().contains("\"attention") }
        let conversation = CardConversation(store: store)
        conversation.select(card.id)
        #expect(!conversation.context.isEmpty && isPrivate(conversation.context))
        #expect(isPrivate(String(decoding: try JSONEncoder().encode(store.workspace), as: UTF8.self)))
        #expect(store.cards[0].disposition == .mine && store.cards[0].tracking?.changes.count == 1)
        // Runs, the card database and everything else Noteling keeps beside the ledger.
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { !$0.path.contains("/attention/") && !$0.hasDirectoryPath } ?? []
        #expect(files.contains { $0.path.contains("/runs/") } && files.contains { $0.lastPathComponent == "morning.sqlite" })
        for file in files { #expect(isPrivate(String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)), "\(file.lastPathComponent)") }
        if let log = try? Data(contentsOf: Config.logFile) { #expect(!String(decoding: log, as: UTF8.self).contains("PRIVATE-EXPLAIN-TEXT-7")) }
    }

    // MARK: - Fixtures

    /// A card a card step made before the ledger started, with three options and a way to gather context. Its mail
    /// job has been read since, without the card's message, unless `read` is false: then only another job was read
    /// through a script, and the card's source is one the test does not read.
    @MainActor private final class Fixture {
        let root: URL
        let sourceID = UUID(), runID = UUID()
        let repository: CountingRepository
        let store: MorningStore
        let ledger: AttentionLedger
        let cardID: UUID
        var key: String { CardObservation.key(sourceID: sourceID, itemKey: "lease@rent.example.test") }
        var file: URL { root.appendingPathComponent("attention/signals.jsonl") }
        var events: [AttentionEvent] { AttentionLogFile.read(file).events }
        var implicit: [AttentionEvent.Implicit] { events.compactMap { if case .implicit(let value) = $0.payload { return value }; return nil } }
        var labels: [AttentionEvent.Label] { events.compactMap { if case .label(let value) = $0.payload { return value }; return nil } }

        init(read: Bool = true) {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-labels-\(UUID())")
            var workspace = MorningWorkspace()
            let at = Date().addingTimeInterval(-3_600)
            var card = MorningCard(folderID: workspace.folders[1].id, title: "Dana needs the signed lease by Friday",
                sources: [MorningSource(title: "Lease renewal: sign by Friday", kind: "mail", excerpt: "Please sign the renewal by Friday.",
                                        url: "https://mail.example.test/lease", capturedAt: at)],
                rationale: "The renewal lapses Friday; signing keeps this rent.",
                action: MorningAction(title: "Draft a reply", instruction: "Draft a short reply to Dana."),
                contextAction: MorningAction(title: "Find the current lease", instruction: "Find the current lease terms."), updatedAt: at)
            card.alternatives = [MorningAction(title: "Add Friday to calendar", instruction: "Add a Friday reminder to sign."),
                                 MorningAction(title: "Open the lease portal", instruction: "Open the landlord's portal.", mode: .desktop)]
            card.tracking = CardTracking(sourceID: sourceID, itemKey: "lease@rent.example.test", sourceName: "Example Gmail",
                identityEvidence: "Message-ID lease@rent.example.test", firstSeenAt: at, lastSeenAt: at, lastRunID: runID,
                contentFingerprint: "fingerprint", resolutionEvidence: "Visible in the inbox",
                changes: [CardChange(at: at, runID: runID, message: "Created from collected source information.")])
            workspace.cards = [card]
            cardID = card.id
            repository = CountingRepository(workspace)
            store = MorningStore(repository: repository)
            let zone = TimeZone(identifier: "America/New_York")!, started = Date().addingTimeInterval(-60)
            let job = AttentionEvent.Sorted.Source(sourceID: read ? sourceID : UUID(), sourceName: "Example Gmail", script: "imap-mail__today",
                runID: UUID(), collectedAt: started, since: at, arrived: 0, returned: 0, truncated: false)
            try? AttentionLogFile(url: root.appendingPathComponent("attention/signals.jsonl")).append([
                AttentionEvent(.started, at: started, timeZone: zone),
                AttentionEvent(.sorted(.init(runIDs: [job.runID], backfilled: false, sources: [job], items: [])), at: started, timeZone: zone)])
            ledger = AttentionLedger(directory: root.appendingPathComponent("attention"), timeZone: zone)
            ledger.watch(store)
        }

        /// The implicit events one store change wrote.
        func signals(_ change: () throws -> Void) rethrows -> [AttentionEvent.Implicit] {
            let before = implicit.count
            try change()
            return Array(implicit.dropFirst(before))
        }

        func reopened() -> AttentionLedger {
            AttentionLedger(directory: root.appendingPathComponent("attention"), timeZone: TimeZone(identifier: "America/New_York")!)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class CountingRepository: MorningRepository {
        var workspace: MorningWorkspace?
        private(set) var saves = 0
        init(_ workspace: MorningWorkspace) { self.workspace = workspace }
        func load() throws -> LoadedMorningWorkspace? { workspace.map { LoadedMorningWorkspace(workspace: $0) } }
        func save(_ workspace: MorningWorkspace) throws { saves += 1; self.workspace = workspace }
    }
}
