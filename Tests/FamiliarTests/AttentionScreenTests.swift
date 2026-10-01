import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Familiar

/// The daily line on the folders screen opens the day's rest in one tap, and the week is one chip from there. The rest
/// lists what was shown, with the card's thumbs, and then everything left out, each with "Matters to me".
/// Scrolling to its end is what checks the day. None of it changes a card.
@Suite @MainActor
struct AttentionScreenTests {
    private static let tuesday = "2026-09-29", wednesday = "2026-09-30"

    @Test func theDailyLineOpensTheRestInOneTap() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let line = try #require(find(AttentionDailyLine.self, in: fixture.view(.folders).body))
        #expect(line.line?.text == "Read 42 → showed 6 · you said yes to 0 · 36 in the rest")
        #expect(find(Text.self, in: line.body) != nil)
        line.tap()
        #expect(fixture.navigation.route == .attention(.rest(day: Self.wednesday)))

        // Nothing read in the last seven days: the line is in the folders screen but shows nothing.
        let later = try Fixture(now: Fixture.at("2026-10-08", "09:00"))
        defer { later.remove() }
        let quiet = try #require(find(AttentionDailyLine.self, in: later.view(.folders).body))
        #expect(quiet.line == nil && find(Text.self, in: quiet.body) == nil)

        // Without the ledger there is no line at all.
        #expect(find(AttentionDailyLine.self, in: fixture.view(.folders, attention: false).body) == nil)
    }

    @Test func withoutAScriptReadTheFoldersScreenIsUnchanged() throws {
        let fixture = try Fixture(read: false)
        defer { fixture.remove() }
        let with = try #require(pixels(fixture.view(.folders))), without = try #require(pixels(fixture.view(.folders, attention: false)))
        // Compared first, so a failure does not diff millions of bytes.
        let same = with == without
        #expect(same, "The folders screen changed for someone without a script read.")
        #expect(Set(with).count > 2)   // the folders were drawn, not a blank panel
    }

    /// The first read's line couldn't be written, so there is no line and no thumbs yet. The failure is said where the
    /// line would be, as long as a job reads mail through a script.
    @Test func aLogThatCantBeWrittenIsSaidBeforeTheFirstLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-unsaved-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: root.appendingPathComponent("attention"))
        let sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
        let job = LearnedReadingSource(kind: .mail, name: "Example Gmail", meaning: "My personal inbox",
            scope: "Show anything that needs a reply", script: "imap-mail__today")
        try sources.saveReadingSource(job)
        let rows: [[String: Any]] = (0..<3).map { ["key": "m\($0)@mail.example.test", "title": "Message \($0)", "tab": "primary"] }
        try sources.saveReadingSnapshot(try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": 3, "items": rows],
            request: ReadingReadRequest(source: job), collectedAt: Fixture.at("2026-09-30", "08:00")))
        let store = MorningStore(directory: root.appendingPathComponent("morning"))
        let ledger = AttentionLedger(directory: root.appendingPathComponent("attention"), clock: { Fixture.at("2026-09-30", "09:30") },
                                     timeZone: Fixture.zone)
        let input = CardGenerationInput.saved(in: sources, runID: nil, excluding: [])
        try store.applyCardGeneration(observations: input.observations, proposals: [], runIDs: input.runIDs)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: sources.runStore, cards: store.cards)
        let error = try #require(ledger.error)
        #expect(ledger.numbers.line == nil)

        let navigation = MorningNavigation()
        func view(attention: Bool = true) -> MorningFilesView {
            MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in }, calendarSources: sources,
                             discussCard: { _ in }, attention: attention ? ledger : nil)
        }
        let failing = try #require(find(AttentionDailyLine.self, in: view().body))
        #expect(failing.line == nil && failing.error == error && find(Text.self, in: failing.body) != nil)

        // Once no job reads mail through a script, the test is not running, so nothing of it shows.
        try sources.removeSource(id: job.id)
        let removed = try #require(find(AttentionDailyLine.self, in: view().body))
        #expect(ledger.error == error && removed.error == nil && find(Text.self, in: removed.body) == nil)
    }

    @Test func theWeekIsOneChipAway() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let rest = try fixture.restView()
        #expect(rest.day == Self.wednesday && rest.days(fixture.ledger.numbers) == [Self.wednesday, Self.tuesday])
        rest.openWeek()
        #expect(fixture.navigation.route == .attention(.week))

        let screen = try #require(find(AttentionScreenView.self, in: fixture.view().body))
        let week = try #require(find(AttentionWeekView.self, in: screen.body))
        week.open(Self.tuesday)
        #expect(fixture.navigation.route == .attention(.rest(day: Self.tuesday)))
        let tuesday = try fixture.restView(Self.tuesday)
        #expect(tuesday.day == Self.tuesday)
        tuesday.open(Self.wednesday)
        #expect(fixture.navigation.route == .attention(.rest(day: Self.wednesday)))
    }

    /// A mail job read from the screen ran in Wednesday's card step. It is named at the top of Wednesday's rest and
    /// among the week's footnotes, and removing it is suggested only while it is still in Manage sources.
    @Test func aScreenReadMailJobIsNamedWhereItsDayIsCounted() throws {
        let gmail = LearnedReadingSource(kind: .mail, name: "Gmail inbox – today’s unread", meaning: "My personal inbox",
            application: "Google Chrome", url: "https://mail.google.com/mail/u/0/#inbox", scope: "Today's unread messages")
        let fixture = try Fixture(screenRead: gmail)
        defer { fixture.remove() }
        let sources = CalendarStore(directory: fixture.root.appendingPathComponent("calendar"))
        try sources.saveReadingSource(gmail)
        let ran = "Your screen-read mail job “Gmail inbox – today’s unread” also ran today."
        let remove = " If it reads the same inbox, a message shown on its card can land in the rest here, and removing it in Manage sources"
            + " keeps the numbers clean."
        let numbers = fixture.ledger.numbers, days = try #require(numbers.week)
        let rest = try fixture.restView(sources: sources), week = try fixture.weekView(sources: sources)
        #expect(rest.screenRead(numbers) == ran + remove && week.screenRead(numbers, days) == ran + remove)
        #expect(try fixture.restView(Self.tuesday, sources: sources).screenRead(numbers) == nil)
        // Their numbers are the same: the line only says why a message on its card can be in the rest.
        #expect(numbers.day(Self.wednesday).read == 42 && numbers.day(Self.wednesday).shown == 6)

        try sources.removeSource(id: gmail.id)
        let removed = ran + " If it read the same inbox, a message shown on its card can land in the rest here."
        #expect(rest.screenRead(numbers) == removed && week.screenRead(numbers, days) == removed)
        // A pack that doesn't know the jobs still suggests it.
        #expect(try fixture.restView().screenRead(numbers) == ran + remove)
        // Without one, neither screen has the line.
        let plain = try Fixture()
        defer { plain.remove() }
        let plainWeek = try #require(plain.ledger.numbers.week)
        #expect(try plain.restView().screenRead(plain.ledger.numbers) == nil)
        #expect(try plain.weekView().screenRead(plain.ledger.numbers, plainWeek) == nil)
    }

    @Test func routesAreExhaustive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(MorningPanelController.preferredHeight(for: .attention(.rest(day: Self.tuesday))) == 680)
        #expect(MorningPanelController.preferredHeight(for: .attention(.week)) == 680)
        #expect(AttentionScreen.rest(day: Self.tuesday).heading == "The rest" && AttentionScreen.week.heading == "This week")
        for screen in [AttentionScreen.rest(day: Self.wednesday), .rest(day: Self.tuesday), .week] {
            fixture.view(.attention(screen)).back()
            #expect(fixture.navigation.route == .folders)
        }
        // A view built without the ledger says so rather than showing an empty screen.
        #expect(find(AttentionScreenView.self, in: fixture.view(.attention(.week), attention: false).body) == nil)
        #expect(AttentionOpen.route(.attention(.week)) == "other")
    }

    @Test func shouldHaveShownMeToggles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = fixture.store.workspace
        let rest = try fixture.restView(), numbers = fixture.ledger.numbers
        let items = numbers.restItems(on: Self.wednesday)
        // The likeliest miss comes first: the one Gmail marked important.
        let statement = try #require(items.items.first)
        #expect(statement.key == fixture.key("w", 6) && items.items.count == 14 && items.lists.count == 22)
        let row = rest.row(statement, numbers)
        #expect(row.details == "Sender 6 · Primary · 8:54 · important")
        #expect(rest.row(try #require(items.lists.first), numbers).details == "Sender 20 · Promotions · 8:40 · list")

        row.toggleMiss()
        #expect(fixture.misses.map(\.retract) == [false] && fixture.misses.first?.key == statement.key && row.isMissed)
        #expect(fixture.ledger.numbers.day(Self.wednesday).missed == 1)
        #expect(fixture.store.lesson(for: statement.key)?.verdict == .matters)
        row.toggleMiss()
        #expect(fixture.misses.map(\.retract) == [false, true] && !row.isMissed)
        #expect(fixture.ledger.numbers.day(Self.wednesday).missed == 0)
        // It only ever teaches: it never makes a card or touches the desk, and taking it back leaves no lesson.
        #expect(fixture.store.cards == before.cards && fixture.store.workItems == before.workItems && fixture.store.lessons.isEmpty)
    }

    @Test func reachingTheEndChecksTheDayOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let rest = try fixture.restView()
        #expect(fixture.ledger.numbers.line?.text == "Read 42 → showed 6 · you said yes to 0 · 36 in the rest")
        rest.reachedEnd()
        rest.reachedEnd()
        #expect(fixture.restViews == [.init(restDay: Self.wednesday, count: 36, reachedEnd: true, seconds: 0)])
        #expect(fixture.ledger.numbers.line?.text == "Read 42 → showed 6 · you said yes to 0 · 0 missed")
    }

    @Test func onlyScrollingToTheEndChecksTheDay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Tuesday's rest is short, so its end is on screen at once; Wednesday's 36 reach far below the panel.
        fixture.navigation.route = .attention(.rest(day: Self.tuesday))
        let screen = OnScreen(fixture.view())
        defer { screen.close() }
        await screen.wait { !fixture.restViews.isEmpty }
        #expect(fixture.restViews.map(\.reachedEnd) == [true] && fixture.restViews.first?.restDay == Self.tuesday)
        fixture.navigation.route = .attention(.rest(day: Self.wednesday))
        await screen.wait(for: 0.1)
        fixture.navigation.route = .folders
        await screen.wait { fixture.restViews.count > 1 }
        #expect(fixture.restViews.map { "\($0.restDay) \($0.reachedEnd)" } == ["\(Self.tuesday) true", "\(Self.wednesday) false"])
        #expect(fixture.ledger.numbers.day(Self.tuesday).restChecked && !fixture.ledger.numbers.day(Self.wednesday).restChecked)
    }

    @Test func aLookAtTheRestEndsWhenThePackCloses() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(MorningPanelController.route(afterHiding: .attention(.rest(day: Self.wednesday))) == .folders)
        #expect(MorningPanelController.route(afterHiding: .attention(.week)) == .folders)
        #expect(MorningPanelController.route(afterHiding: .card(fixture.cardID)) == .card(fixture.cardID))
        #expect(MorningPanelController.route(afterHiding: .sources) == .sources)

        // Closed a minute into Wednesday's long rest, as the panel closes: the look ends then, and says how long it was.
        fixture.navigation.route = .attention(.rest(day: Self.wednesday))
        let screen = OnScreen(fixture.view())
        defer { screen.close() }
        await screen.wait(for: 0.1)
        fixture.ledger.clock = { Fixture.at(Self.wednesday, "09:31") }
        fixture.navigation.route = MorningPanelController.route(afterHiding: fixture.navigation.route)
        await screen.wait { !fixture.restViews.isEmpty }
        #expect(fixture.restViews == [.init(restDay: Self.wednesday, count: 36, reachedEnd: false, seconds: 60)])

        // Left open on the rest overnight and moved on by Who's Who on Thursday: that is no look at the rest, so
        // Thursday is not a day the pack was opened.
        fixture.ledger.clock = { Fixture.at(Self.wednesday, "18:00") }
        fixture.navigation.route = .attention(.rest(day: Self.wednesday))
        await screen.wait(for: 0.1)
        fixture.ledger.clock = { Fixture.at("2026-10-01", "08:00") }
        fixture.navigation.route = .people
        await screen.wait(for: 0.1)
        #expect(fixture.restViews.count == 1 && fixture.ledger.numbers.day("2026-10-01").firstOpen == nil)
    }

    @Test func aReadThatLandsLaterNeverSwapsTheRestOnScreen() async throws {
        let thursday = "2026-10-01"
        let fixture = try Fixture(now: Fixture.at(thursday, "09:30"))
        defer { fixture.remove() }
        // Nothing is read yet on Thursday, so the line is about Wednesday, and its tap opens Wednesday's rest by name.
        let line = try #require(find(AttentionDailyLine.self, in: fixture.view(.folders).body))
        line.tap()
        #expect(fixture.navigation.route == .attention(.rest(day: Self.wednesday)))
        let screen = OnScreen(fixture.view())
        defer { screen.close() }
        await screen.wait(for: 0.1)
        // A read from chat lands while it is open. The line moves on to Thursday, but the screen stays on Wednesday,
        // so Thursday's short rest is not checked by a look no one took.
        try fixture.readTheInbox(at: Fixture.at(thursday, "09:35"), subjects: ["Gym hours", "Library hold", "Weekly digest"])
        #expect(fixture.ledger.numbers.line?.day == thursday && fixture.ledger.numbers.day(thursday).restCount == 3)
        await screen.wait(for: 0.1)
        #expect(fixture.restViews.isEmpty && fixture.navigation.route == .attention(.rest(day: Self.wednesday)))
        #expect(!fixture.ledger.numbers.day(thursday).restChecked)
    }

    @Test func shownRowsReuseTheThumbs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = fixture.store.workspace
        let rest = try fixture.restView()
        let row = rest.shownRow(fixture.key("w", 0))
        let card = try #require(row.card)
        #expect(card.id == fixture.cardID)
        let thumbs = try #require(find(AttentionThumbs.self, in: row.body))
        #expect(thumbs.via == .shown && thumbs.key == fixture.key("w", 0))
        thumbs.tap(.up)
        #expect(fixture.labels.map(\.via) == [.shown] && fixture.labels.first?.value == .yes)
        #expect(fixture.labels.first?.card?.cardID == fixture.cardID && fixture.store.workspace == before)
        row.open(card.id)
        #expect(fixture.navigation.route == .card(fixture.cardID))

        // A shown message whose card is gone keeps its subject, with nothing to label it against.
        let gone = rest.shownRow(fixture.key("w", 1))
        #expect(gone.card == nil && find(AttentionThumbs.self, in: gone.body) == nil && find(Text.self, in: gone.body) != nil)
    }

    /// A shown message whose only card came from a job that reads the mail from the screen, and named its Message-ID,
    /// opens that card from its row and has thumbs for the message there; the card itself stays as it was.
    @Test func aShownRowFindsTheScreenCardThatNamedItsMessage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let screenID = UUID()
        let observation = CardObservation(runID: UUID(), sourceID: screenID, itemKey: "row-1", sourceName: "Gmail inbox – today’s unread",
            kind: "mail", title: "Plumber visit", excerpt: "The plumber comes Thursday.",
            url: "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Aw1%40mail.example.test", identityEvidence: "Visible row",
            observedAt: Fixture.at("2026-09-30", "09:00"), state: .open, stateEvidence: "Not confirmed yet.")
        try fixture.store.applyCardGeneration(observations: [observation], proposals: [CardProposal(observationKey: observation.id,
            title: "Confirm the plumber for Thursday", meaning: "He needs a yes by noon.",
            action: MorningAction(title: "Draft a reply", instruction: "Draft a short yes."))], runIDs: [observation.runID])
        let screenCard = try #require(fixture.store.cards.first { $0.tracking?.sourceID == screenID })
        let before = fixture.store.workspace
        let row = try fixture.restView().shownRow(fixture.key("w", 1))
        #expect(row.card?.id == screenCard.id)
        let thumbs = try #require(find(AttentionThumbs.self, in: row.body))
        #expect(thumbs.message == fixture.key("w", 1) && thumbs.key == fixture.key("w", 1) && thumbs.via == .shown)
        thumbs.tap(.down)
        #expect(fixture.labels.map(\.key) == [fixture.key("w", 1)] && fixture.labels.first?.value == .no)
        #expect(fixture.labels.first?.card?.cardID == screenCard.id && fixture.labels.first?.item.shown == true)
        #expect(fixture.store.workspace == before && fixture.ledger.labelKey(for: screenCard) == nil)
        row.open(screenCard.id)
        #expect(fixture.navigation.route == .card(screenCard.id))
        // Its own card still comes first, with the card's own thumbs, and a message no card names keeps its subject.
        let own = try fixture.restView().shownRow(fixture.key("w", 0))
        #expect(own.card?.id == fixture.cardID && find(AttentionThumbs.self, in: own.body)?.message == nil)
        #expect(try fixture.restView().shownRow(fixture.key("w", 2)).card == nil)
    }

    @Test func aRestRowCanBeExplained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let numbers = fixture.ledger.numbers
        let item = try #require(numbers.restItems(on: Self.wednesday).items.first)
        let row = try fixture.restView().row(item, numbers)
        #expect(!row.isExplaining && find(AttentionRowExplainField.self, in: row.body) == nil)

        fixture.ledger.beginExplaining(item.key)
        let field = try #require(find(AttentionRowExplainField.self, in: row.body))
        field.save("Statements are never urgent.")
        let explained = try #require(fixture.labels.last)
        #expect(explained.value == .explain && explained.via == .rest && explained.text == "Statements are never urgent.")
        #expect(explained.key == item.key && explained.card == nil && explained.item.shown == false)
        #expect(fixture.ledger.explaining == nil && fixture.ledger.effective(for: item.key).state == .notSet)
        #expect(fixture.store.lesson(for: item.key)?.why == "Statements are never urgent." && fixture.store.lesson(for: item.key)?.verdict == nil)
        field.save("after it closed")
        #expect(fixture.labels.count == 1)
    }

    /// What the person teaches in the test, "Matters to me" and why in the rest and thumbs on a card, reaches the
    /// lessons the card step reads, as the app wires it.
    @Test func whatThePersonTeachesBecomesLessons() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.ledger.onTaught = { try? fixture.store.teach($0, $1) }
        let numbers = fixture.ledger.numbers
        let statement = try #require(numbers.restItems(on: Self.wednesday).items.first)
        let row = try fixture.restView().row(statement, numbers)
        row.toggleMiss()
        let lesson = try #require(fixture.store.lesson(for: statement.key))
        #expect(lesson.verdict == .matters && lesson.title == "Message w6" && lesson.from == "Sender 6")
        #expect(lesson.sourceID == fixture.sourceID && lesson.sourceName == "Example Gmail")
        fixture.ledger.beginExplaining(statement.key)
        try #require(find(AttentionRowExplainField.self, in: row.body)).save("My bank statement")
        #expect(fixture.store.lesson(for: statement.key)?.why == "My bank statement")
        row.toggleMiss()   // taking the mark back takes its words too
        #expect(fixture.store.lesson(for: statement.key) == nil)

        // A card's thumbs: yes, then very; the other thumb switches sides, then very, then clears.
        let card = try #require(fixture.store.cards.first), key = fixture.key("w", 0)
        var verdicts: [MorningLesson.Verdict?] = []
        for thumb in [AttentionLabels.Thumb.up, .up, .down, .down, .down] {
            fixture.ledger.tapThumb(key: key, card: card, thumb: thumb, via: .card)
            verdicts.append(fixture.store.lesson(for: key)?.verdict)
        }
        #expect(verdicts == [.matters, .mattersALot, .notForMe, .notAtAll, nil])
        #expect(fixture.store.lesson(for: key) == nil)   // nothing left to teach
        fixture.ledger.tapThumb(key: key, card: card, thumb: .up, via: .card)
        #expect(fixture.store.lesson(for: key)?.title == "Message w0" && fixture.store.cards.count == 1)
    }

    /// A message marked on a run's results and one marked in the rest are the same lesson and the same count: each
    /// place shows what the other did, a why given in one opens in the other, and Forget unmarks both.
    @Test func runResultsAndTheRestShowTheSameLesson() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let numbers = fixture.ledger.numbers
        let statement = try #require(numbers.restItems(on: Self.wednesday).items.first)
        let facts = LessonFacts(key: statement.key, sourceID: fixture.sourceID, sourceName: "Example Gmail",
                                title: statement.subject, from: "Sender 6")
        let runTeacher = LessonTeacher(morning: fixture.store, attention: fixture.ledger, facts: facts)
        try runTeacher.mark(true)
        try runTeacher.explain("My bank statement")
        let row = try fixture.restView().row(statement, numbers)
        #expect(row.isMissed && fixture.ledger.isMissed(statement.key) && fixture.ledger.numbers.day(Self.wednesday).missed == 1)
        #expect(fixture.ledger.explanation(for: statement.key) == "My bank statement")
        fixture.ledger.beginExplaining(statement.key)
        #expect(try #require(find(AttentionRowExplainField.self, in: row.body)).initial == "My bank statement")
        fixture.ledger.cancelExplaining()

        // A newer why from the rest wins, and the run results show it.
        fixture.ledger.beginExplaining(statement.key)
        try #require(find(AttentionRowExplainField.self, in: row.body)).save("Statements can wait a week")
        #expect(runTeacher.lesson?.why == "Statements can wait a week" && runTeacher.matters)

        LessonsView(morning: fixture.store, attention: fixture.ledger).forget(try #require(runTeacher.lesson))
        #expect(runTeacher.lesson == nil && !row.isMissed && !fixture.ledger.isMissed(statement.key))
        #expect(fixture.ledger.numbers.day(Self.wednesday).missed == 0)
    }

    @Test func backFromWhatYouveTaughtGoesWhereItWasOpened() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let run = MorningNavigation.Route.sourceRun(runID: UUID(), sourceID: nil)
        fixture.navigation.lessonsReturn = run
        fixture.view(.lessons).back()
        #expect(fixture.navigation.route == run)
        fixture.navigation.lessonsReturn = nil
        fixture.view(.lessons).back()
        #expect(fixture.navigation.route == .latestRun)
    }

    // MARK: - Fixtures

    /// An example inbox read by a card step on Tuesday (5 messages, 1 shown) and Wednesday (42 messages, 6 shown, one
    /// of them on a card), with a Morning store watched by the ledger. It is Wednesday 09:30 in New York unless `now`
    /// says otherwise. Without `read` the ledger has never seen a script read.
    @MainActor private final class Fixture {
        static let zone = TimeZone(identifier: "America/New_York")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-screens-\(UUID())")
        let sourceID = UUID()
        let store: MorningStore
        let ledger: AttentionLedger
        let navigation = MorningNavigation()
        let cardID: UUID
        var file: URL { root.appendingPathComponent("attention/signals.jsonl") }
        var events: [AttentionEvent] { AttentionLogFile.read(file).events }
        var labels: [AttentionEvent.Label] { events.compactMap { if case .label(let value) = $0.payload { return value }; return nil } }
        var misses: [AttentionEvent.Miss] { events.compactMap { if case .miss(let value) = $0.payload { return value }; return nil } }
        var restViews: [AttentionEvent.RestViewed] {
            events.compactMap { if case .restViewed(let value) = $0.payload { return value }; return nil }
        }

        /// A local time in New York, four hours behind UTC in September.
        nonisolated static func at(_ day: String, _ time: String) -> Date { AttentionTime.date("\(day)T\(time):00.000-04:00")! }

        init(now: Date = Fixture.at("2026-09-30", "09:30"), read: Bool = true, screenRead: LearnedReadingSource? = nil) throws {
            let started = Self.at("2026-09-29", "07:00")
            var events = [AttentionEvent(.started, at: started, timeZone: Self.zone)]
            if read {
                events.append(Self.sorted(Self.at("2026-09-29", "08:00"), prefix: "t", count: 5, shown: 1, source: sourceID))
                events.append(Self.sorted(Self.at("2026-09-30", "09:00"), prefix: "w", count: 42, shown: 6, source: sourceID,
                    screenRead: screenRead.map { [.init(sourceID: $0.id, sourceName: $0.name)] }))
            }
            try AttentionLogFile(url: root.appendingPathComponent("attention/signals.jsonl")).append(events)
            store = MorningStore(directory: root.appendingPathComponent("morning"))
            ledger = AttentionLedger(directory: root.appendingPathComponent("attention"), clock: { now }, timeZone: Self.zone)
            ledger.watch(store)
            let observation = CardObservation(runID: UUID(), sourceID: sourceID, itemKey: "w0@mail.example.test", sourceName: "Example Gmail",
                kind: "mail", title: "Lease renewal: sign by Friday", excerpt: "Please sign the renewal by Friday.",
                url: "https://mail.example.test/w0", identityEvidence: "Message-ID w0@mail.example.test",
                observedAt: Self.at("2026-09-30", "09:00"), state: .open, stateEvidence: "Not signed yet.")
            try store.applyCardGeneration(observations: [observation], proposals: [CardProposal(observationKey: observation.id,
                title: "Dana needs the signed lease by Friday", meaning: "The renewal lapses Friday; signing keeps this rent.",
                action: MorningAction(title: "Draft a reply", instruction: "Draft a short reply to Dana."))], runIDs: [observation.runID])
            cardID = try #require(store.cards.first).id
        }

        func key(_ prefix: String, _ index: Int) -> String { Self.key(prefix, index, source: sourceID) }

        private static func key(_ prefix: String, _ index: Int, source: UUID) -> String {
            CardObservation.key(sourceID: source, itemKey: "\(prefix)\(index)@mail.example.test")
        }

        /// One card step's read of the inbox at `at`: messages a minute apart, newest first. The seventh is marked
        /// important, and from the 21st on they are promotions from mailing lists.
        private static func sorted(_ at: Date, prefix: String, count: Int, shown: Int, source sourceID: UUID,
                                   screenRead: [AttentionEvent.Sorted.ScreenRead]? = nil) -> AttentionEvent {
            let runID = UUID()
            let items = (0..<count).map { (index: Int) -> AttentionItem in
                let list = index >= 20, received = at.addingTimeInterval(-Double(index) * 60)
                return AttentionItem(key: key(prefix, index, source: sourceID), sourceID: sourceID, sourceName: "Example Gmail",
                    kind: "mail", script: "imap-mail__today", runID: runID, itemID: "\(prefix)\(index)", readAt: at,
                    subject: "Message \(prefix)\(index)", fromName: "Sender \(index)", tab: list ? "promotions" : "primary", bulk: list,
                    important: index == 6, received: received, preview: "", url: "https://mail.example.test/\(prefix)\(index)",
                    shown: index < shown)
            }
            let read = AttentionEvent.Sorted.Source(sourceID: sourceID, sourceName: "Example Gmail", script: "imap-mail__today",
                runID: runID, collectedAt: at, since: at.addingTimeInterval(-86_400), arrived: count, returned: count, truncated: false)
            return AttentionEvent(.sorted(.init(runIDs: [runID], backfilled: false, sources: [read], items: items, screenRead: screenRead)),
                                  at: at, timeZone: Self.zone)
        }

        /// The pack on `route`, as the panel builds it, with the ledger unless `attention` is false, and with the jobs
        /// in Manage sources when `sources` gives them.
        func view(_ route: MorningNavigation.Route? = nil, attention: Bool = true, sources: CalendarStore? = nil) -> MorningFilesView {
            if let route { navigation.route = route }
            return MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
                                    calendarSources: sources, discussCard: { _ in }, attention: attention ? ledger : nil)
        }

        /// The rest screen of `day`, Wednesday unless it says otherwise, as the pack shows it.
        func restView(_ day: String = AttentionScreenTests.wednesday, sources: CalendarStore? = nil) throws -> AttentionRestView {
            let screen = try #require(find(AttentionScreenView.self, in: view(.attention(.rest(day: day)), sources: sources).body))
            return try #require(find(AttentionRestView.self, in: screen.body))
        }

        /// The week, as the pack shows it.
        func weekView(sources: CalendarStore? = nil) throws -> AttentionWeekView {
            let screen = try #require(find(AttentionScreenView.self, in: view(.attention(.week), sources: sources).body))
            return try #require(find(AttentionWeekView.self, in: screen.body))
        }

        /// A card step reads a second example inbox at `at` and shows none of it, as a read from chat would.
        func readTheInbox(at: Date, subjects: [String]) throws {
            let sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
            let job = LearnedReadingSource(kind: .mail, name: "Example Mail", meaning: "A second inbox",
                scope: "Show anything that needs a reply", script: "imap-mail__today")
            try sources.saveReadingSource(job)
            let rows: [[String: Any]] = subjects.enumerated().map { index, subject in
                ["key": "late\(index)@mail.example.test", "title": subject, "from": "Sender <sender@example.test>", "tab": "primary"]
            }
            try sources.saveReadingSnapshot(try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": rows.count, "items": rows],
                request: ReadingReadRequest(source: job), collectedAt: at))
            let input = CardGenerationInput.saved(in: sources, runID: nil, excluding: [])
            ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: sources.runStore, cards: store.cards, at: at)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// A view in an offscreen window, as the panel shows it, long enough for its appear and disappear actions to run. It
/// waits by sleeping, never by running the run loop, so other suites' main-actor work goes on meanwhile.
@MainActor private final class OnScreen {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 680), styleMask: [.borderless],
                                  backing: .buffered, defer: false)

    init<V: View>(_ view: V) {
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 650, height: 680))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Until `done`, or a second at most.
    func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !done(), Date() < deadline { await wait(for: 0.01) }
    }

    func wait(for seconds: TimeInterval) async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(seconds))
    }

    func close() { window.close() }
}

/// The view drawn in a window at the panel's width and the folders screen's height, as the render draws it but without
/// waiting on the run loop.
@MainActor private func pixels<V: View>(_ view: V) -> Data? {
    let size = NSSize(width: 650, height: MorningPanelController.preferredHeight(for: .folders))
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    return bitmap.bitmapData.map { Data(bytes: $0, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }
}

/// Finds a view composed inside a SwiftUI body, without GUI coordinates.
private func find<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> T? {
    if let value = value as? T { return value }
    guard depth < 60 else { return nil }
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle != .class else { return nil }
    for child in mirror.children {
        if let result = find(type, in: child.value, depth: depth + 1) { return result }
    }
    return nil
}
