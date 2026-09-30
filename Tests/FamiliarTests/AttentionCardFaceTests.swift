import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Familiar

/// The card face gains two thumbs on its header line and "Let me explain…" in its ⋯ menu, nothing more. Thumbs and
/// explanations only label the item: they never change the card. Only cards from a source the test reads have them.
@Suite @MainActor
struct AttentionCardFaceTests {
    @Test func thumbsAppearOnlyOnSourceCards() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let thumbs = try #require(fixture.onCard(fixture.cardID, find: AttentionThumbs.self))
        #expect(thumbs.key == fixture.key && thumbs.card.id == fixture.cardID && thumbs.via == .card)
        #expect(find(Image.self, in: thumbs.body) != nil)
        #expect(fixture.onCard(fixture.cardID, find: AttentionExplainMenuItem.self) != nil)

        let note = MorningCard(folderID: fixture.store.folders[0].id, title: "Call the plumber",
            action: MorningAction(title: "Find the number", instruction: "Find the plumber's number."))
        try fixture.store.saveCard(note)
        try fixture.store.loadSamples()
        let sample = try #require(fixture.store.cards.first { $0.isSample })
        for id in [note.id, sample.id] {
            let none = try #require(fixture.onCard(id, find: AttentionThumbs.self))
            #expect(none.key == nil && find(Image.self, in: none.body) == nil)
        }

        // A view built without the ledger, as in the render and older callers, has no thumbs at all.
        let navigation = MorningNavigation()
        navigation.route = .card(fixture.cardID)
        let plain = MorningFilesView(store: fixture.store, navigation: navigation, close: {}, filed: {}, handoff: { _ in })
        #expect(find(AttentionThumbs.self, in: plain.body) == nil && find(AttentionExplainSlot.self, in: plain.body) == nil)
        #expect(find(AttentionExplainMenuItem.self, in: plain.body) == nil)
    }

    @Test func tapSequence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = fixture.store.workspace
        let thumbs = try #require(fixture.onCard(fixture.cardID, find: AttentionThumbs.self))

        for _ in 0..<3 { thumbs.tap(.up) }
        #expect(fixture.labels.map(\.value) == [.yes, .strongYes, .clear])
        thumbs.tap(.up)
        thumbs.tap(.down)
        #expect(fixture.labels.map(\.value) == [.yes, .strongYes, .clear, .yes, .no])
        #expect(fixture.labels.allSatisfy { $0.via == .card && $0.key == fixture.key && $0.card?.cardID == fixture.cardID })
        #expect(fixture.ledger.effective(for: fixture.key).state == .no)
        // Labels, not commands: the card, its folder and its work are as they were.
        #expect(fixture.store.workspace == before && fixture.implicit.isEmpty)
    }

    @Test func explainSlotShowsOnlyWhileExplaining() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger, key = fixture.key
        let shut = try #require(fixture.onCard(fixture.cardID, find: AttentionExplainSlot.self))
        #expect(!shut.isOpen && find(TextField<Text>.self, in: shut.body) == nil)

        ledger.beginExplaining(key)
        let slot = try #require(fixture.onCard(fixture.cardID, find: AttentionExplainSlot.self))
        #expect(slot.isOpen && find(TextField<Text>.self, in: slot.body) != nil)
        slot.save("because rent")
        let explained = try #require(fixture.labels.last)
        #expect(explained.value == .explain && explained.text == "because rent" && explained.via == .card && explained.key == key)
        #expect(ledger.explaining == nil && ledger.explanation(for: key) == "because rent")
        #expect(ledger.effective(for: key).state == .notSet)   // words never set a yes or a no
        slot.save("after it closed")
        #expect(fixture.labels.count == 1)

        ledger.beginExplaining(key)
        slot.save(String(repeating: "a", count: 2_500))
        #expect(ledger.explanation(for: key)?.count == AttentionLabels.explanationLimit && ledger.explaining == nil)
        let thumbs = try #require(fixture.onCard(fixture.cardID, find: AttentionThumbs.self))
        #expect(find(Image.self, in: thumbs.body) != nil)
    }

    @Test func aSaveThatCannotBeWrittenKeepsTheWords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger, key = fixture.key
        ledger.beginExplaining(key)
        let slot = try #require(fixture.onCard(fixture.cardID, find: AttentionExplainSlot.self))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.file.path)
        slot.save("because rent")
        // The field stays open with the words in it, and says why.
        #expect(slot.isOpen && ledger.explaining == key)
        #expect(ledger.error == "Couldn’t save the attention test in Noteling’s attention folder (error \(EACCES)). Your cards aren’t affected.")
        #expect(ledger.explanation(for: key) == nil && fixture.labels.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        slot.save("because rent")
        #expect(!slot.isOpen && ledger.explanation(for: key) == "because rent" && ledger.error == nil && fixture.labels.count == 1)
    }

    @Test func aCardOnScreenIsRecordedAsOpened() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let note = MorningCard(folderID: fixture.store.folders[0].id, title: "Call the plumber",
            action: MorningAction(title: "Find the number", instruction: "Find the plumber's number."))
        try fixture.store.saveCard(note)
        let navigation = MorningNavigation()
        navigation.route = .card(fixture.cardID)
        let screen = OnScreen(MorningFilesView(store: fixture.store, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
                                               attention: fixture.ledger))
        defer { screen.close() }
        #expect(fixture.engaged.map(\.key) == [fixture.key] && fixture.engaged.first?.what == .cardOpened)

        navigation.route = .card(note.id)
        screen.wait()
        #expect(fixture.engaged.count == 1)   // a hand-written note is not part of the test
        navigation.route = .card(fixture.cardID)
        screen.wait()
        #expect(fixture.engaged.map(\.key) == [fixture.key, fixture.key])
    }

    @Test func aCalendarOrScreenCardHasNoThumbs() throws {
        // Its labels would never count, and its key can be made of the item's own words, such as a sender, a subject
        // and a date, so opening it is recorded by a digest of that key.
        let fixture = try Fixture(read: false)
        defer { fixture.remove() }
        let ledger = fixture.ledger, key = fixture.key
        let thumbs = try #require(fixture.onCard(fixture.cardID, find: AttentionThumbs.self))
        #expect(ledger.labelKey(for: try #require(fixture.store.cards.first)) == nil)
        #expect(thumbs.key == nil && find(Image.self, in: thumbs.body) == nil)
        let menuItem = try #require(fixture.onCard(fixture.cardID, find: AttentionExplainMenuItem.self))
        #expect(find(Button<Text>.self, in: menuItem.body) == nil)
        ledger.beginExplaining(key)
        #expect(fixture.onCard(fixture.cardID, find: AttentionExplainSlot.self)?.isOpen == false)

        ledger.cardOpened(try #require(fixture.store.cards.first))
        let opened = try #require(fixture.engaged.first)
        #expect(fixture.engaged.count == 1 && opened.key != key && opened.key.hasPrefix(fixture.sourceID.uuidString.lowercased() + ":"))
        #expect(ledger.index.firstActive[AttentionTime.day(of: Date(), in: ledger.timeZone)] != nil)
        let written = String(decoding: try Data(contentsOf: fixture.file), as: UTF8.self)
        #expect(!written.contains("lease@rent.example.test") && !written.contains("Lease renewal"))
    }

    @Test func cardOpenedIsAnEngagementNotALabel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger, key = fixture.key
        try fixture.store.setDisposition(cardID: fixture.cardID, to: .mine)
        let card = try #require(fixture.store.cards.first { $0.id == fixture.cardID })
        let before = ledger.effective(for: key)
        #expect(ledger.index.firstActive.isEmpty)   // what the person did to the card is a guess, not a visit

        ledger.cardOpened(card)
        let engaged = fixture.engaged
        #expect(engaged.count == 1 && engaged.first?.key == key && engaged.first?.what == .cardOpened)
        #expect(engaged.first?.card.cardID == fixture.cardID && engaged.first?.card.disposition == .mine)
        #expect(ledger.effective(for: key) == before && before.state == .guessYes && fixture.labels.isEmpty)
        // It counts as using the pack that day.
        #expect(ledger.index.firstActive[AttentionTime.day(of: Date(), in: ledger.timeZone)] != nil)

        try fixture.store.loadSamples()
        let sample = try #require(fixture.store.cards.first { $0.isSample })
        let note = MorningCard(folderID: fixture.store.folders[0].id, title: "Call the plumber",
            action: MorningAction(title: "Find the number", instruction: "Find the plumber's number."))
        ledger.cardOpened(sample)
        ledger.cardOpened(note)
        #expect(fixture.events.filter { $0.type == .engaged }.count == 1)
    }

    @Test func aGuessNamesWhatThePersonDid() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let card = try #require(fixture.store.cards.first)
        #expect(AttentionThumbs.reason(.mine, card: card) == "you chose “I’ll do it”")
        #expect(AttentionThumbs.reason(.ignored, card: card) == "you chose “Ignore”")
        #expect(AttentionThumbs.reason(.handled, card: card) == "you chose “I’ve handled this”")
        var withContext = card
        withContext.contextAction = MorningAction(title: "Find the current lease", instruction: "Find the lease terms.")
        #expect(AttentionThumbs.reason(.contextRequested, card: withContext) == "you chose “Find the current lease”")
        #expect(AttentionThumbs.reason(.contextRequested, card: card) == "you asked for more context")
    }

    // MARK: - Fixtures

    /// One card a card step made from an example inbox, on a Morning store with a ledger watching it. The ledger has
    /// a script read of the inbox, unless `read` is false, as for a calendar or a screen read: then it has only
    /// another job's script read.
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-card-face-\(UUID())")
        let sourceID = UUID()
        let store: MorningStore
        let ledger: AttentionLedger
        let cardID: UUID
        let key: String
        var file: URL { root.appendingPathComponent("attention/signals.jsonl") }
        var events: [AttentionEvent] { AttentionLogFile.read(file).events }
        var labels: [AttentionEvent.Label] { events.compactMap { if case .label(let value) = $0.payload { return value }; return nil } }
        var implicit: [AttentionEvent.Implicit] { events.compactMap { if case .implicit(let value) = $0.payload { return value }; return nil } }
        var engaged: [AttentionEvent.Engaged] { events.compactMap { if case .engaged(let value) = $0.payload { return value }; return nil } }

        init(read: Bool = true) throws {
            let zone = TimeZone(identifier: "America/New_York")!, started = Date().addingTimeInterval(-60)
            let job = AttentionEvent.Sorted.Source(sourceID: read ? sourceID : UUID(), sourceName: "Example Gmail", script: "imap-mail__today",
                runID: UUID(), collectedAt: started, since: started.addingTimeInterval(-86_400), arrived: 0, returned: 0, truncated: false)
            try AttentionLogFile(url: root.appendingPathComponent("attention/signals.jsonl")).append([
                AttentionEvent(.started, at: started, timeZone: zone),
                AttentionEvent(.sorted(.init(runIDs: [job.runID], backfilled: false, sources: [job], items: [])), at: started, timeZone: zone)])
            store = MorningStore(directory: root.appendingPathComponent("morning"))
            ledger = AttentionLedger(directory: root.appendingPathComponent("attention"), timeZone: zone)
            ledger.watch(store)
            let observation = CardObservation(runID: UUID(), sourceID: sourceID, itemKey: "lease@rent.example.test", sourceName: "Example Gmail",
                kind: "mail", title: "Lease renewal: sign by Friday", excerpt: "Please sign the renewal by Friday.",
                url: "https://mail.example.test/lease", identityEvidence: "Message-ID lease@rent.example.test",
                observedAt: Date(), state: .open, stateEvidence: "Not signed yet.")
            try store.applyCardGeneration(observations: [observation], proposals: [CardProposal(observationKey: observation.id,
                title: "Dana needs the signed lease by Friday", meaning: "The renewal lapses Friday; signing keeps this rent.",
                action: MorningAction(title: "Draft a reply", instruction: "Draft a short reply to Dana."))], runIDs: [observation.runID])
            cardID = try #require(store.cards.first).id
            key = observation.id
        }

        /// The view of a card on screen, with the ledger, as the panel builds it.
        func onCard<T>(_ cardID: UUID, find type: T.Type) -> T? {
            let navigation = MorningNavigation()
            navigation.route = .card(cardID)
            let view = MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
                                        discussCard: { _ in }, attention: ledger)
            return find(type, in: view.body)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// A view in an offscreen window, as the panel shows it, long enough for its tasks to run.
@MainActor private final class OnScreen {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 640), styleMask: [.borderless],
                                  backing: .buffered, defer: false)

    init<V: View>(_ view: V) {
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 650, height: 640))
        wait()
    }

    func wait() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func close() { window.close() }
}

/// Finds a view composed inside a SwiftUI body, without GUI coordinates.
private func find<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> T? {
    if let value = value as? T { return value }
    guard depth < 60 else { return nil }   // the ⋯ menu's items sit deeper than the rest of the card
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle != .class else { return nil }
    for child in mirror.children {
        if let result = find(type, in: child.value, depth: depth + 1) { return result }
    }
    return nil
}
