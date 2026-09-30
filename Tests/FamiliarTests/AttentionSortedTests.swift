import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

/// Each card step's receipt becomes one `sorted` line in the attention ledger: every item its script reads returned,
/// whether the step showed it as a card, and each read's own counts, under the key the card carries. Only script
/// reads count, a receipt is written once, and one saved without its line is recorded at the next launch.
@Suite @MainActor
struct AttentionSortedTests {
    @Test func theRestAndTheCardsShareOneKey() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        // Message-IDs keep their case in the run; the card and the ledger both lowercase them for the key.
        let run = try fixture.read(5, key: { "<M\($0).Lease@Example.test>" })
        let input = try fixture.sort(showing: 2)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        let sorted = try #require(fixture.sorted.first)
        let snapshot = try #require(fixture.sources.runStore.run(id: run)?.entries.first?.readingSnapshot)
        #expect(sorted.items.map(\.key) == input.observations.map(\.id))
        #expect(sorted.items.map(\.itemID) == snapshot.items.map(\.id))
        #expect(sorted.items.map(\.key) == snapshot.items.map {
            CardObservation.key(sourceID: fixture.job.id, itemKey: CardGenerationInput.identity($0.identityKey, fallback: $0.id))
        })
        let carded = fixture.morning.cards.compactMap { $0.tracking?.key }
        #expect(carded.count == 2 && Set(carded) == Set(sorted.items.filter(\.shown).map(\.key)))
        #expect(Set(ledger.index.firstDay.keys) == Set(input.observations.map(\.id)) && ledger.index.shownKeys == Set(carded))
    }

    @Test func aReceiptWritesOneSortedLine() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        let readAt = Self.date("2026-09-30T13:00:00.250Z")
        let run = try fixture.read(40, arrived: 64, at: readAt, cutOffSinceLastRead: 9)
        let input = try fixture.sort(showing: 6)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        let events = AttentionLogFile.read(fixture.file).events
        #expect(events.map(\.type) == [.started, .sorted])
        let sorted = try #require(fixture.sorted.first)
        #expect(sorted.runIDs == [run] && !sorted.backfilled)
        #expect(sorted.items.count == 40 && sorted.items.filter(\.shown).count == 6)
        #expect(sorted.sources == [.init(sourceID: fixture.job.id, sourceName: "Example Gmail", script: "imap-mail__today", runID: run,
            collectedAt: readAt, since: Self.date("2026-09-29T12:00:00Z"), arrived: 64, returned: 40, truncated: true,
            cutOffSinceLastRead: 9)])
        #expect(ledger.index.sortedRunIDs == [run] && ledger.index.sortedReads[fixture.job.id]?.map(\.arrived) == [64])
        // The script counted 9 of the 24 it left out as arriving after the last sorted read: only those were never read.
        #expect(ledger.index.sortedReads[fixture.job.id]?.map(\.cutOff) == [9])
        #expect(ledger.revision == 1 && ledger.error == nil)   // one write: the line, after the start it brought
    }

    @Test func recordingTwiceAddsNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        try fixture.read(3)
        let input = try fixture.sort(showing: 1)
        let record = { (ledger: AttentionLedger) in
            ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        }
        record(ledger)
        let once = try Data(contentsOf: fixture.file)

        record(ledger)
        ledger.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(try Data(contentsOf: fixture.file) == once)

        // After a restart the file says which runs are recorded, and it is not started again.
        let restarted = fixture.ledger()
        #expect(restarted.index.sortedRunIDs == Set(input.runIDs) && restarted.index.startedAt == ledger.index.startedAt)
        record(restarted)
        restarted.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(try Data(contentsOf: fixture.file) == once)
    }

    @Test func onlyScriptSourcesAreCounted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        let taught = LearnedReadingSource(kind: .mail, name: "Work mail", meaning: "My work inbox",
            url: "https://mail.example.test/inbox", scope: "Recent unread messages")
        try fixture.sources.saveReadingSource(taught)
        let calendar = LearnedCalendarSource(name: "Work", meaning: "Work schedule", application: "Calendar",
            account: "alex@example.test", calendarName: "Work", timeZoneID: "America/New_York")
        try fixture.sources.saveSource(calendar)
        let saveOthers = { (at: Date) in
            try fixture.sources.saveReadingSnapshot(ReadingSnapshot(requestID: UUID(), sourceID: taught.id, source: taught, collectedAt: at,
                items: [ReadingItem(id: "row-1", title: "Budget review", text: "Budget review is due", evidence: "Visible row")],
                coverage: .complete, accountEvidence: "Current account", sourceEvidence: "Inbox", scopeEvidence: "Recent rows"))
            let event = CalendarEventRecord(id: "one", title: "Design review", start: at, end: at.addingTimeInterval(3_600),
                response: .accepted, availability: .busy, evidence: "Design review accepted busy")
            try fixture.sources.saveSnapshot(CalendarSnapshot(sourceID: calendar.id, day: at, timeZoneID: calendar.timeZoneID, events: [event],
                coverage: .complete, accountEvidence: "alex@example.test", calendarEvidence: "Work calendar", dateEvidence: "Sep 30",
                collectedAt: at, source: calendar))
        }
        let now = Date()
        // Someone whose jobs read only a window they taught and a calendar gets no log at all: the card step makes
        // their cards and they use the pack, but nothing is written, not even the folder.
        ledger.watch(fixture.morning)
        try saveOthers(now.addingTimeInterval(-60))
        let unread = try fixture.sort(showing: 2)
        ledger.recordSorted(unread.observations, runIDs: unread.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        ledger.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        let card = try #require(fixture.morning.cards.first)
        ledger.recordOpened(.launcher, route: .folders, desk: 2, wasOpen: false)
        ledger.cardOpened(card)
        try fixture.morning.setDisposition(cardID: card.id, to: .mine)
        ledger.tapThumb(key: try #require(card.tracking?.key), card: card, thumb: .up, via: .card)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.deletingLastPathComponent().path))
        #expect(ledger.error == nil && ledger.pending.isEmpty && ledger.revision == 0 && ledger.index.startedAt == nil)

        // The first step that reads mail through a script starts the file with its line; what follows is written.
        let script = try fixture.read(3, at: now)
        try saveOthers(now)
        let mixed = try fixture.sort(showing: 5)   // every item gets a card, the taught and calendar ones too
        #expect(mixed.runIDs.count == 3 && mixed.observations.count == 5)
        ledger.recordSorted(mixed.observations, runIDs: mixed.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        ledger.recordOpened(.menu, route: .folders, desk: 5, wasOpen: false)
        let events = AttentionLogFile.read(fixture.file).events
        #expect(events.map(\.type) == [.started, .sorted, .opened] && events[0].at == events[1].at)
        #expect(ledger.index.startedAt == events[1].at && ledger.revision == 2)

        let sorted = try #require(fixture.sorted.first)
        #expect(sorted.runIDs == mixed.runIDs)   // the whole receipt, so it is never recorded twice
        #expect(sorted.sources.map(\.runID) == [script] && sorted.items.count == 3)
        #expect(sorted.items.allSatisfy { $0.sourceID == fixture.job.id && $0.shown })

        // A step that read no script source writes no line at all.
        let before = try Data(contentsOf: fixture.file)
        try saveOthers(now.addingTimeInterval(60))
        let others = try fixture.sort(showing: 0)
        #expect(others.runIDs.count == 2)
        ledger.recordSorted(others.observations, runIDs: others.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        ledger.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(try Data(contentsOf: fixture.file) == before)

        // The sixth day after the read is still in its week. A week with no script read, as after the mail job was
        // removed, ends the test: its cards have no thumbs and nothing the person does is written, until the next read.
        var days = Calendar(identifier: .gregorian)
        days.timeZone = ledger.timeZone
        let mail = try #require(fixture.morning.cards.first { $0.tracking?.sourceID == fixture.job.id })
        let mailKey = try #require(mail.tracking?.key)
        let sixth = try #require(days.date(byAdding: .day, value: 6, to: now))
        ledger.clock = { sixth }
        #expect(ledger.isRunning && ledger.labelKey(for: mail) == mailKey)
        let week = try #require(days.date(byAdding: .day, value: 7, to: now))
        ledger.clock = { week }
        #expect(!ledger.isRunning && ledger.labelKey(for: mail) == nil)
        ledger.recordOpened(.launcher, route: .folders, desk: 5, wasOpen: false)
        ledger.cardOpened(mail)
        try fixture.morning.setDisposition(cardID: mail.id, to: .mine)
        ledger.tapThumb(key: mailKey, card: mail, thumb: .up, via: .card)
        ledger.miss(key: mailKey)
        ledger.restViewed(day: events[1].day, count: 0, reachedEnd: true, seconds: 5)
        #expect(try Data(contentsOf: fixture.file) == before && ledger.error == nil && ledger.pending.isEmpty)

        try fixture.read(2, key: { "next-\($0)@example.test" }, at: week)
        let next = try fixture.sort(showing: 1, at: week)
        ledger.recordSorted(next.observations, runIDs: next.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        ledger.recordOpened(.launcher, route: .folders, desk: 6, wasOpen: false)
        #expect(AttentionLogFile.read(fixture.file).events.map(\.type) == [.started, .sorted, .opened, .sorted, .opened])
        #expect(ledger.isRunning && ledger.labelKey(for: mail) == mailKey)
    }

    /// The founder's Gmail is read twice in one card step: through the script and by a job taught on the screen. The
    /// step cards only the screen's copies, so each script copy counts as shown only when a card names its Message-ID.
    @Test func aScreenReadCardThatNamesTheMessageShowsTheScriptCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        try fixture.read(3)
        let screen = try fixture.readTheScreen(Self.screenCopies)
        let input = try fixture.sort { $0.sourceID == screen.id }
        #expect(fixture.morning.cards.count == 3 && fixture.morning.cards.allSatisfy { $0.tracking?.sourceID == screen.id })
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        let sorted = try #require(fixture.sorted.first)
        // m0 is named by the Message-ID the screen saw, m1 by its Gmail link; m2's card names only its sender and subject.
        #expect(sorted.items.map(\.key) == (0..<3).map { CardObservation.key(sourceID: fixture.job.id, itemKey: "m\($0)@example.test") })
        #expect(sorted.items.map(\.shown) == [true, true, false])
        // The line names the screen's job, by its id and name only, so the numbers can say it ran that day.
        let line = try #require(String(contentsOf: fixture.file, encoding: .utf8).split(separator: "\n").last)
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let named = try #require(json["screenRead"] as? [[String: String]])
        #expect(named == [["sourceID": screen.id.uuidString, "sourceName": "Gmail inbox – today’s unread"]])
        #expect(sorted.screenRead == [.init(sourceID: screen.id, sourceName: "Gmail inbox – today’s unread")])
        let today = AttentionTime.day(of: Date(), in: ledger.timeZone), numbers = ledger.numbers
        #expect(numbers.day(today).read == 3 && numbers.day(today).shown == 2)
        #expect(numbers.screenRead(on: [today]) == "Your screen-read mail job “Gmail inbox – today’s unread” also ran today. If it reads"
            + " the same inbox, a message shown on its card can land in the rest here, and removing it in Manage sources keeps the numbers clean.")
        // A step that read only the script names nothing, and a card that names no Message-ID shows nothing else.
        try fixture.read(2, key: { "later-\($0)@example.test" })
        let alone = try fixture.sort(showing: 0)
        ledger.recordSorted(alone.observations, runIDs: alone.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        #expect(fixture.sorted.count == 2 && fixture.sorted.last?.screenRead == nil && fixture.sorted.last?.items.contains(where: \.shown) == false)
    }

    /// What the person does to a screen-read card that named a message's Message-ID is about that message: the yes
    /// guessed from it counts for the script's copy, and the rest's Shown row finds the card. A screen card that named
    /// no Message-ID is still recorded by a digest of its own key, and no screen card gets thumbs on its face.
    @Test func actingOnAScreenCardThatNamedTheMessageLabelsTheScriptCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        ledger.watch(fixture.morning)
        try fixture.read(3)
        let screen = try fixture.readTheScreen(Self.screenCopies)
        let input = try fixture.sort { $0.sourceID == screen.id }
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        let script = (0..<3).map { CardObservation.key(sourceID: fixture.job.id, itemKey: "m\($0)@example.test") }
        let cards = fixture.morning.cards
        func card(_ index: Int) throws -> MorningCard { try #require(cards.first { $0.title == "About Message \(index)" }) }
        let m0 = try card(0), m1 = try card(1), m2 = try card(2)
        #expect(ledger.shownKey(namedBy: m0) == script[0] && ledger.shownKey(namedBy: m1) == script[1] && ledger.shownKey(namedBy: m2) == nil)
        #expect(ledger.card(showing: script[0], in: cards)?.id == m0.id && ledger.card(showing: script[1], in: cards)?.id == m1.id)
        #expect(ledger.card(showing: script[2], in: cards) == nil)
        #expect(cards.allSatisfy { ledger.labelKey(for: $0) == nil })   // the cards stay as they were

        try fixture.morning.setDisposition(cardID: m0.id, to: .mine)
        ledger.cardOpened(m1)
        try fixture.morning.setDisposition(cardID: m2.id, to: .ignored)
        let events = AttentionLogFile.read(fixture.file).events
        let implicit = events.compactMap { if case .implicit(let value) = $0.payload { return value }; return nil }
        let engaged = events.compactMap { if case .engaged(let value) = $0.payload { return value }; return nil }
        #expect(implicit.count == 2 && implicit[0].key == script[0] && implicit[0].item.key == script[0] && implicit[0].item.shown)
        #expect(implicit[0].item.subject == "Message 0" && implicit[0].card.cardID == m0.id)
        #expect(implicit[1].key.hasPrefix(screen.id.uuidString.lowercased() + ":") && implicit[1].item.subject.isEmpty)
        #expect(engaged.map(\.key) == [script[1]])
        let today = AttentionTime.day(of: Date(), in: ledger.timeZone)
        var day = ledger.numbers.day(today)
        #expect(day.shown == 2 && day.yesGuessed == 1 && day.yesTapped == 0 && day.leftAlone == 1)

        // A thumb for the message, as the rest's Shown row gives it, counts as tapped.
        ledger.tapThumb(key: script[1], card: m1, thumb: .up, via: .shown)
        day = ledger.numbers.day(today)
        #expect(day.yesTapped == 1 && day.leftAlone == 0 && ledger.effective(for: script[1]).explicit == .yes)
        let label = try #require(AttentionLogFile.read(fixture.file).events.last?.payload)
        guard case .label(let written) = label else { Issue.record("Expected a label"); return }
        #expect(written.key == script[1] && written.item.shown && written.card?.cardID == m1.id)
    }

    /// Monday's step, with the screen's job beside the script, is written at once; Tuesday's is saved just before
    /// Noteling quit, and the next launch writes its line with the same job named and the same Message-ID matched.
    @Test func aBackfilledStepNamesTheScreenReadJobToo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let monday = Self.date("2026-09-28T12:00:00Z"), tuesday = Self.date("2026-09-29T12:00:00Z")
        let ledger = fixture.ledger(clock: monday)
        try fixture.read(3, at: monday)
        let screen = try fixture.readTheScreen(Self.screenCopies, at: monday)
        let first = try fixture.sort(at: monday) { $0.sourceID == screen.id }
        ledger.recordSorted(first.observations, runIDs: first.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        try fixture.read(2, key: { "t\($0)@example.test" }, at: tuesday)
        try fixture.readTheScreen([ReadingItem(id: "row-t0", title: "Message 0", text: "Sender 0 · Message 0", evidence: "Visible row",
            identityKey: "t0@example.test", identityEvidence: "Message-ID in the headers")], at: tuesday)
        try fixture.sort(at: tuesday) { $0.sourceID == screen.id }
        let relaunched = fixture.ledger(clock: tuesday.addingTimeInterval(3_600))
        relaunched.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)

        let lines = fixture.sorted
        #expect(lines.count == 2 && lines[1].backfilled && lines.allSatisfy { $0.screenRead?.map(\.sourceID) == [screen.id] })
        #expect(lines[1].items.map(\.shown) == [true, false])
        let numbers = relaunched.numbers
        #expect(numbers.screenRead(on: ["2026-09-28", "2026-09-29"]) == "Your screen-read mail job “Gmail inbox – today’s unread”"
            + " also ran on 2 days. If it reads the same inbox, a message shown on its card can land in the rest here, and removing it"
            + " in Manage sources keeps the numbers clean.")
        // Once it is removed there is nothing to suggest, but those days were still read beside it.
        #expect(numbers.screenRead(on: ["2026-09-28", "2026-09-29"], active: [fixture.job.id]) == "Your screen-read mail job"
            + " “Gmail inbox – today’s unread” also ran on 2 days. If it read the same inbox, a message shown on its card can land in the rest here.")
    }

    @Test func theCardStepWritesSortedOnlyWhenItSucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        var fail = false, stop: (() -> Void)?
        let service = fixture.service { _, _, messages, executor in
            if fail { throw MorningStoreError.invalid("The model is unavailable.") }
            let submitted = await executor(CardGenerationSubmission.toolName, ["proposals": [Self.proposal(try Self.key(in: messages))]], nil)
            #expect(!submitted.isError)
            stop?()
            return "Ready"
        }
        service.onSorted = { observations, runIDs in
            ledger.recordSorted(observations, runIDs: runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        }

        try fixture.read(3)
        await service.generate()?.value
        try fixture.read(2, key: { "later-\($0)@example.test" })
        await service.generate()?.value
        let receipts = fixture.morning.workspace.cardGenerations ?? []
        #expect(receipts.count == 2 && service.error == nil)
        #expect(fixture.sorted.map(\.runIDs) == receipts.map(\.runIDs))
        #expect(fixture.sorted.map { $0.items.count } == [3, 2] && fixture.sorted.map { $0.items.filter(\.shown).count } == [1, 1])
        let written = try Data(contentsOf: fixture.file)

        fail = true
        try fixture.read(2, key: { "failed-\($0)@example.test" })
        await service.generate()?.value
        #expect(service.error?.contains("unavailable") == true)

        fail = false
        stop = { service.stop() }
        await service.generate()?.value
        #expect(service.status == "Card generation stopped.")
        #expect((fixture.morning.workspace.cardGenerations ?? []).count == 2)
        #expect(try Data(contentsOf: fixture.file) == written)
    }

    /// The next read goes back to the last read a card step sorted, never to one no step sorted. Read on Monday at
    /// 08:00, Tuesday skipped; Wednesday's 08:00 read reaches back over Tuesday, but its card step fails, and when it is
    /// tried again the person presses Stop. The Read pressed again at 08:15 goes back to Monday, not to Wednesday 08:00,
    /// so the mail from Monday 08:00 to Tuesday 08:15 is read and can land in the rest, and the week has no stretch
    /// left unread.
    @Test func aReadNoCardStepSortedNeverMovesTheNextReadsWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let monday = Self.date("2026-09-28T08:00:00.000-04:00"), wednesday = Self.date("2026-09-30T08:00:00.000-04:00")
        let again = Self.date("2026-09-30T08:15:00.000-04:00")
        var now = monday
        let ledger = AttentionLedger(directory: fixture.root.appendingPathComponent("attention"), clock: { now }, timeZone: Self.newYork)
        var fail = false, stop: (() -> Void)?
        let service = fixture.service { _, _, messages, executor in
            if fail { throw MorningStoreError.invalid("The model is unavailable.") }
            let submitted = await executor(CardGenerationSubmission.toolName, ["proposals": [Self.proposal(try Self.key(in: messages))]], nil)
            #expect(!submitted.isError)
            stop?()
            return "Ready"
        }
        service.onSorted = { observations, runIDs in
            ledger.recordSorted(observations, runIDs: runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        }
        #expect(fixture.lastSortedRead == nil)   // no sorted read yet: the usual day

        try fixture.read(3, at: monday, since: monday.addingTimeInterval(-86_400))
        await service.generate()?.value
        #expect(fixture.lastSortedRead == monday)

        now = wednesday
        let unsorted = try fixture.read(2, key: { "wednesday-\($0)@example.test" }, at: wednesday, since: monday.addingTimeInterval(-3_600))
        fail = true
        await service.generate()?.value
        #expect(service.error?.contains("unavailable") == true)
        fail = false
        stop = { service.stop() }
        await service.generate()?.value
        #expect(service.status == "Card generation stopped.")
        #expect(fixture.morning.workspace.cardGenerations?.count == 1 && fixture.sources.runStore.run(id: unsorted) != nil)

        now = again
        let lastRead = fixture.lastSortedRead
        #expect(lastRead == monday)
        // 48¼ hours since, rounded up, plus the hour's margin: back to Monday 06:15.
        let hours = ScriptReadWindow.hours(lastRead: lastRead, now: again)
        #expect(hours == 50)
        stop = nil
        try fixture.read(2, key: { "again-\($0)@example.test" }, at: again, since: again.addingTimeInterval(-Double(hours) * 3_600))
        await service.generate()?.value
        #expect(fixture.sorted.count == 2 && fixture.sorted.last?.items.map(\.key).allSatisfy { $0.contains("again-") } == true)
        #expect(fixture.lastSortedRead == again)
        #expect(ledger.numbers.week?.gaps == [])   // before, "Not read: Mon 28 08:00 → Tue 29 08:15"
    }

    /// The read window comes from the card step's receipts, not from the attention test. Deleting the test's folder, as
    /// the privacy notice says to erase it, starts the test again but never shortens a read: Friday's read was sorted,
    /// the folder is deleted that evening, and Monday's read still goes back to Friday, so the weekend's mail is read.
    @Test func deletingTheAttentionFolderNeverShortensTheNextRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let friday = Self.date("2026-09-25T08:00:00.000-04:00"), monday = Self.date("2026-09-28T08:00:00.000-04:00")
        let ledger = fixture.ledger(clock: friday)
        try fixture.read(3, at: friday)
        let input = try fixture.sort(showing: 1, at: friday)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        #expect(ledger.index.sortedReads[fixture.job.id]?.last?.collectedAt == friday)

        try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
        let relaunched = fixture.ledger(clock: monday)
        #expect(relaunched.index.sortedReads.isEmpty && relaunched.index.startedAt == nil)   // the test starts again
        #expect(fixture.lastSortedRead == friday)
        #expect(ScriptReadWindow.hours(lastRead: fixture.lastSortedRead, now: monday) == 73)   // not the usual 24
    }

    @Test func aJobRemovedWhileItsStepRanIsNeverBackfilled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The test began an hour ago with an earlier read.
        let begun = Date().addingTimeInterval(-3_600)
        try AttentionLogFile(url: fixture.file).append([AttentionEvent(.started, at: begun, timeZone: Self.newYork),
                                                        Self.sorted(AttentionTime.string(begun, in: Self.newYork), keys: ["earlier"])])
        let written = try Data(contentsOf: fixture.file)
        let ledger = fixture.ledger()
        let service = fixture.service { _, _, messages, executor in
            // The person removes the job while the model is still reading its mail.
            try fixture.sources.removeSource(id: fixture.job.id)
            let submitted = await executor(CardGenerationSubmission.toolName, ["proposals": [Self.proposal(try Self.key(in: messages))]], nil)
            #expect(!submitted.isError)
            return "Ready"
        }
        service.onSorted = { observations, runIDs in
            ledger.recordSorted(observations, runIDs: runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        }
        let run = try fixture.read(3)
        await service.generate()?.value
        #expect(fixture.morning.workspace.cardGenerations?.map(\.runIDs) == [[run]] && fixture.morning.cards.isEmpty)
        #expect(fixture.sources.runStore.run(id: run) != nil && service.error == nil)   // its run is kept, so a restart can find it
        #expect(try Data(contentsOf: fixture.file) == written)

        fixture.ledger().backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(try Data(contentsOf: fixture.file) == written && fixture.sorted.count == 1)
    }

    @Test func backfillClosesTheCrashWindowButNeverReachesBeforeTheStart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let early = Self.date("2026-09-29T13:00:00Z"), start = Self.date("2026-09-29T20:00:00Z"), late = Self.date("2026-09-30T13:00:00.123Z")
        try fixture.read(3, at: early)
        try fixture.sort(showing: 1, at: early)   // a receipt from before the ledger existed

        // A ledger with no start pulls nothing in, so a new or deleted one starts clean.
        let ledger = fixture.ledger(clock: start)
        ledger.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        // The first read it is told of starts it.
        try fixture.read(2, key: { "first-\($0)@example.test" }, at: start)
        let first = try fixture.sort(showing: 0, at: start)
        ledger.recordSorted(first.observations, runIDs: first.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        // Saved, but Noteling quit before its line was written.
        try fixture.read(4, key: { "later-\($0)@example.test" }, at: late)
        let missed = try fixture.sort(showing: 2, at: late)
        let restarted = fixture.ledger(clock: late.addingTimeInterval(3_600))
        restarted.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)

        let events = AttentionLogFile.read(fixture.file).events
        #expect(events.map(\.type) == [.started, .sorted, .sorted] && events[0].at == start && events[1].at == start)
        #expect(fixture.sorted.first?.runIDs == first.runIDs && fixture.sorted.first?.backfilled == false)
        #expect(events[2].at == late && events[2].day == "2026-09-30")   // the receipt's own time, not the launch's
        let sorted = try #require(fixture.sorted.last)
        #expect(sorted.backfilled && sorted.runIDs == missed.runIDs)
        #expect(sorted.items.map(\.key) == missed.observations.map(\.id) && sorted.items.filter(\.shown).count == 2)
        #expect(sorted.sources.map(\.collectedAt) == [late])

        let once = try Data(contentsOf: fixture.file)
        restarted.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        fixture.ledger().backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(try Data(contentsOf: fixture.file) == once)
    }

    @Test func aMessageReadAgainIsListedByItsKeyAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // 08:00 and 20:00 in New York: the evening's 24 hours reach back over five of the morning's ten messages.
        let morning = Self.date("2026-09-30T12:00:00Z"), evening = Self.date("2026-10-01T00:00:00Z")
        let ledger = fixture.ledger(clock: evening)
        try fixture.read(10, at: morning)
        let first = try fixture.sort(showing: 2, at: morning)
        ledger.recordSorted(first.observations, runIDs: first.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards, at: morning)
        try fixture.read(10, key: { "m\($0 + 5)@example.test" }, at: evening)
        let second = try fixture.sort(showing: 2, at: evening)   // two of the five read again get a card now
        ledger.recordSorted(second.observations, runIDs: second.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards, at: evening)

        let lines = fixture.sorted
        #expect(lines.count == 2 && lines[0].items.count == 10 && lines[0].seen == nil)
        #expect(lines[1].items.map(\.key) == second.observations.suffix(5).map(\.id) && lines[1].items.allSatisfy { !$0.shown })
        #expect(lines[1].seen == second.observations.prefix(5).enumerated().map { .init(key: $1.id, shown: $0 < 2) })
        let written = try String(contentsOf: fixture.file, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
        let evenings = try #require(JSONSerialization.jsonObject(with: written[2]) as? [String: Any])
        #expect((evenings["items"] as? [Any])?.count == 5 && (evenings["seen"] as? [[String: Any]])?.first?.keys.sorted() == ["key", "shown"])
        #expect(written[2].count * 4 < written[1].count * 3)   // ten messages in each, five of them by key alone

        // The morning's copies stay, dated by the morning; the evening only adds that two of them were shown.
        let again = first.observations[5].id
        #expect(ledger.index.firstDay[again] == "2026-09-30" && ledger.index.item[again]?.readAt == morning)
        #expect(ledger.index.shownKeys == Set((first.observations.prefix(2) + second.observations.prefix(2)).map(\.id)))
        #expect(ledger.index.firstDay.count == 15 && ledger.index.item.count == 15)
        let relaunched = fixture.ledger(clock: evening)
        #expect(relaunched.index.firstDay == ledger.index.firstDay && relaunched.index.shownKeys == ledger.index.shownKeys)
        #expect(relaunched.index.item == ledger.index.item)
    }

    @Test func aLongRunningAppLetsGoOfOldCopies() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Launched on September 1 and never quit: twenty mornings, three new messages each.
        let first = Self.date("2026-09-01T12:00:00Z")
        var now = first
        let ledger = fixture.ledger(clock: first)
        ledger.clock = { now }
        for day in 0..<20 {
            now = first.addingTimeInterval(Double(day) * 86_400)
            try fixture.read(3, key: { "d\(day)-\($0)@example.test" }, at: now)
            let input = try fixture.sort(showing: 0, at: now)
            ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        }
        // On September 20 copies are kept from 14 days back; earlier days keep only when they were read.
        #expect(ledger.index.keepsItemsFrom == "2026-09-06" && ledger.index.firstDay.count == 60)
        #expect(ledger.index.item.count == 15 * 3 && ledger.index.item.values.allSatisfy { $0.readAt >= Self.date("2026-09-06T12:00:00Z") })
        #expect(Set(fixture.ledger(clock: now).index.item.keys) == Set(ledger.index.item.keys))   // as a relaunch would keep
    }

    @Test func aWriteThatOnlyFailsToFlushCountsAsWritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger(clock: Self.date("2026-09-30T13:00:00Z"))
        ledger.file.sync = { _ in
            errno = EIO
            return -1
        }
        let run = try fixture.read(2)
        let input = try fixture.sort(showing: 1)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        ledger.recordOpened(.launcher, route: .folders, desk: 2, wasOpen: false)
        // Their lines are in the file, so the index has them too, and nothing waits to be written again.
        #expect(AttentionLogFile.read(fixture.file).events.map(\.type) == [.started, .sorted, .opened])
        #expect(ledger.index.sortedRunIDs == [run] && ledger.index.firstOpened["2026-09-30"] != nil)
        #expect(ledger.pending.isEmpty && ledger.error == nil && ledger.revision == 2)

        ledger.file.sync = { fsync($0) }
        ledger.recordOpened(.chat, route: .folders, desk: 2, wasOpen: false)
        #expect(AttentionLogFile.read(fixture.file).events.map(\.type) == [.started, .sorted, .opened, .opened])
    }

    @Test func aLineWrittenTwiceCountsOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let monday = Self.sorted("2026-09-28T13:00:00Z", keys: ["a", "b"], shown: ["a"])
        let item = AttentionItem(key: "a", sourceID: Self.mailID, sourceName: "Example Gmail", kind: "mail", runID: UUID(), itemID: "a",
            readAt: monday.at, subject: "Subject a", preview: "", shown: true)
        let card = AttentionCardContext(cardID: UUID(), disposition: .delegated, displayDisposition: .delegated, optionCount: 1,
            optionModes: [.prepare], cardAgeHours: 1, userEdited: false, hasPersonalContext: false, createdByRun: nil)
        let tapped = AttentionEvent(.implicit(.init(key: "a", signal: .optionTapped, optionIndex: 0, optionMode: .prepare, item: item, card: card)),
                                    at: monday.at.addingTimeInterval(60), timeZone: Self.newYork)
        let index = AttentionIndex([monday, tapped, monday, tapped], now: tapped.at, timeZone: Self.newYork)
        #expect(index.sortedReads[Self.mailID]?.count == 1 && index.labels["a"]?.signals == [.optionTapped])

        // A write that failed partway left whole lines and a torn one behind; the retry wrote them all again.
        let log = AttentionLogFile(url: fixture.file)
        try log.append([.init(.started, at: monday.at, timeZone: Self.newYork), monday, tapped])
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: try monday.line().prefix(40))
        try handle.close()
        try log.append([monday, tapped])
        #expect(AttentionLogFile.read(fixture.file).events.count == 5)
        let ledger = fixture.ledger(clock: tapped.at)
        #expect(ledger.index.sortedReads[Self.mailID]?.count == 1 && ledger.index.labels["a"]?.signals == [.optionTapped])
        #expect(ledger.effective(for: "a").state == .guessYes)
    }

    @Test func anEmptyReadStillCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        let run = try fixture.read(0)
        let input = try fixture.sort(showing: 0)
        #expect(input.runIDs == [run] && input.observations.isEmpty)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        let sorted = try #require(fixture.sorted.first)
        let source = try #require(sorted.sources.first)
        #expect(sorted.items.isEmpty && sorted.sources.count == 1)
        #expect(source.runID == run && source.arrived == 0 && source.returned == 0 && !source.truncated)
        #expect(ledger.index.sortedReads[fixture.job.id]?.count == 1 && ledger.index.firstDay.isEmpty)
    }

    @Test func featuresComeFromTheMailFacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger()
        let preview = String(repeating: "Please sign the renewal so the rent stays the same. ", count: 10)
        let link = "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Alease%40rent.example.test"
        let rows: [[String: Any]] = [
            ["key": "lease@rent.example.test", "title": "Lease renewal: sign by Friday", "from": "\"Ruiz, Dana\" <Dana@Rent.Example.test>",
             "received": "2026-09-30T12:10:00+00:00", "unread": true, "starred": true, "tab": "Primary", "important": true, "bulk": false,
             "preview": preview, "url": link],
            ["key": "sale@shop.example.test", "title": "50% off everything", "from": "Shop <deals@shop.example.test>",
             "unread": false, "tab": "promotions", "bulk": true, "preview": ""],
            // A script row may bring its own text instead of mail fields.
            ["key": "invoice-42@billing.example.test", "title": "Invoice 42", "text": "Invoice 42 is overdue.\nPay it by Friday."],
        ]
        let readAt = Self.date("2026-09-30T14:40:00Z")
        let snapshot = try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": 3, "items": rows],
                                                  request: ReadingReadRequest(source: fixture.job), collectedAt: readAt)
        try fixture.sources.saveReadingSnapshot(snapshot)
        let input = try fixture.sort(showing: 1)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        let items = try #require(fixture.sorted.first?.items)
        let lease = items[0], sale = items[1], invoice = items[2]
        #expect(lease.subject == "Lease renewal: sign by Friday" && lease.itemID == snapshot.items[0].id && lease.shown)
        #expect(lease.sourceName == "Example Gmail" && lease.kind == "mail" && lease.script == "imap-mail__today" && lease.readAt == readAt)
        #expect(lease.from == "\"Ruiz, Dana\" <Dana@Rent.Example.test>" && lease.fromName == "Ruiz, Dana")
        #expect(lease.address == "dana@rent.example.test" && lease.domain == "rent.example.test" && lease.tab == "primary")
        #expect(lease.bulk == false && lease.important == true && lease.starred == true && lease.unread == true)
        #expect(lease.received == Self.date("2026-09-30T12:10:00Z"))
        #expect(lease.receivedHour == 8 && lease.receivedWeekday == 4)   // 8:10 on a Wednesday in New York
        #expect(lease.ageHours == 2.5)
        // The preview without the line of mail facts before it, cut to 280 characters.
        #expect(lease.preview.count == AttentionItem.previewLimit && preview.hasPrefix(lease.preview) && lease.url == link)

        #expect(sale.bulk == true && sale.tab == "promotions" && sale.unread == false && sale.important == nil && !sale.shown)
        #expect(sale.received == nil && sale.receivedHour == nil && sale.receivedWeekday == nil && sale.ageHours == nil)
        #expect(sale.preview.isEmpty && sale.url == nil)

        // Without mail facts there is no line of them to drop, so the whole text is the preview.
        #expect(invoice.preview == "Invoice 42 is overdue.\nPay it by Friday." && invoice.from == nil && invoice.tab == nil && invoice.received == nil)
    }

    /// The first read's line can't be written: the folder is a file. The failure is shown and stands while what
    /// follows waits behind it; the card from that read has no thumbs yet, but what the person does to it keeps its own
    /// key and words; and the next card step tries again even when it read no script source, so nothing is lost once
    /// the folder is fixed.
    @Test func aFailedWriteIsShownAndNeverThrown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.file.deletingLastPathComponent()
        try Data("not a folder".utf8).write(to: folder)
        let readAt = Self.date("2026-09-30T12:00:00Z")
        let ledger = fixture.ledger(clock: readAt)
        ledger.watch(fixture.morning)
        // Nothing is written before the first read, so nothing has failed yet.
        #expect(ledger.error == nil && ledger.index.startedAt == nil && ledger.revision == 0)

        try fixture.read(2, at: readAt)
        let first = try fixture.sort(showing: 1, at: readAt)
        ledger.recordSorted(first.observations, runIDs: first.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        #expect(ledger.error == "Couldn’t save the attention test in Noteling’s attention folder (error \(EEXIST)). Your cards aren’t affected.")
        #expect(ledger.index.sortedRunIDs.isEmpty && ledger.revision == 0)   // nothing joins the index that is not on disk
        #expect(ledger.pending.map(\.type) == [.started, .sorted])
        // The card step sorted it, so the next read goes back to it: the test's own failure never shortens a read.
        #expect(fixture.lastSortedRead == readAt)

        // The card from that read shows no thumbs that could not be saved, but it is one the test reads, so what the
        // person does to it is kept under its own key.
        let card = try #require(fixture.morning.cards.first)
        let key = try #require(card.tracking?.key)
        #expect(ledger.labelKey(for: card) == nil)
        try fixture.morning.setDisposition(cardID: card.id, to: .mine)
        // A small write while the folder is still a file fails too: the error stands and the open waits in line.
        ledger.recordOpened(.launcher, route: .folders, desk: 1, wasOpen: false)
        #expect(ledger.error != nil && ledger.pending.map(\.type) == [.started, .sorted, .implicit, .opened])

        // Fixed. The next card step read only a window the person taught, so it has no line of its own, but what
        // waited is written, the start at the first read's time, and the error clears.
        try FileManager.default.removeItem(at: folder)
        try fixture.readATaughtWindow()
        let others = try fixture.sort(showing: 0)
        ledger.recordSorted(others.observations, runIDs: others.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        let events = AttentionLogFile.read(fixture.file).events
        #expect(events.map(\.type) == [.started, .sorted, .implicit, .opened] && events[0].at == readAt)
        #expect(ledger.error == nil && ledger.pending.isEmpty && ledger.revision == 1 && ledger.index.sortedRunIDs == Set(first.runIDs))
        #expect(ledger.labelKey(for: card) == key)   // its read is on disk, so it has thumbs
        guard case .implicit(let mine) = events[2].payload else {
            Issue.record("The guess was not written after the line.")
            return
        }
        #expect(mine.signal == .mine && mine.key == key && mine.item.subject == card.sources.first?.title && !mine.item.subject.isEmpty)
        #expect(ledger.effective(for: key).state == .guessYes)
    }

    @Test func aMessageReadAgainKeepsItsFirstDay() {
        let old = Self.sorted("2026-09-10T13:00:00Z", keys: ["old"])
        let monday = Self.sorted("2026-09-28T13:00:00Z", keys: ["a", "b"])
        let tuesday = Self.sorted("2026-09-29T13:00:00Z", keys: ["b", "c"], shown: ["b"])
        // Backfilled after Tuesday's line: 7:30 PM Sunday in New York.
        let sunday = Self.sorted("2026-09-27T23:30:00Z", keys: ["c"], backfilled: true)

        let index = AttentionIndex([old, monday, tuesday, sunday], now: Self.date("2026-09-30T13:00:00Z"), timeZone: Self.newYork)
        #expect(index.firstDay == ["old": "2026-09-10", "a": "2026-09-28", "b": "2026-09-28", "c": "2026-09-27"])
        #expect(index.keysByDay.filter { !$0.value.isEmpty } == ["2026-09-10": ["old"], "2026-09-28": ["a", "b"], "2026-09-27": ["c"]])
        #expect(index.shownKeys == ["b"] && index.item["b"]?.subject == "Subject b 2026-09-28T13:00:00Z")
        #expect(index.item["c"]?.subject == "Subject c 2026-09-27T23:30:00Z")
        #expect(index.item["old"] == nil && index.keepsItemsFrom == "2026-09-16")   // older than 14 days: only its day
        #expect(index.sortedReads[Self.mailID]?.map(\.day) == ["2026-09-10", "2026-09-27", "2026-09-28", "2026-09-29"])
        #expect(index.startedAt == nil && index.sortedRunIDs.count == 4)

        // A backfilled line that lists a known message by its key alone dates it earlier too, and it keeps its copy.
        let saturday = Self.sorted("2026-09-26T14:00:00Z", keys: [], seen: ["a": false], backfilled: true)
        let moved = AttentionIndex([old, monday, tuesday, sunday, saturday], now: Self.date("2026-09-30T13:00:00Z"), timeZone: Self.newYork)
        #expect(moved.firstDay["a"] == "2026-09-26" && moved.keysByDay["2026-09-28"] == ["b"] && moved.keysByDay["2026-09-26"] == ["a"])
        #expect(moved.item["a"]?.subject == "Subject a 2026-09-28T13:00:00Z")
    }

    /// Reads in Tokyo on Monday and Tuesday at 08:00 and on Wednesday at 01:00, each rest looked through; then, after a
    /// flight east over the date line, a read in Los Angeles on Tuesday at 19:00 that returns only Wednesday's two.
    @Test func aReadThatCarriesAnEarlierDayNeverMovesAMessage() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!, losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let monday = Self.sorted("2026-09-28T08:00:00.000+09:00", keys: ["a", "b"], shown: ["a"], in: tokyo)
        let tuesday = Self.sorted("2026-09-29T08:00:00.000+09:00", keys: ["c", "d"], shown: ["c"], in: tokyo)
        let wednesday = Self.sorted("2026-09-30T01:00:00.000+09:00", keys: ["e", "f"], shown: ["e"], in: tokyo)
        let looked = ["2026-09-28", "2026-09-29", "2026-09-30"].map { day in
            AttentionEvent(.restViewed(.init(restDay: day, count: 1, reachedEnd: true, seconds: 20)),
                           at: Self.date("2026-09-30T02:00:00.000+09:00"), timeZone: tokyo)
        }
        let again = Self.sorted("2026-09-29T19:00:00.000-07:00", keys: ["e", "f"], shown: ["e"], in: losAngeles)
        #expect(tuesday.day == "2026-09-29" && wednesday.day == "2026-09-30" && again.day == "2026-09-29")

        let now = Self.date("2026-09-29T19:05:00.000-07:00")
        let index = AttentionIndex([monday, tuesday, wednesday] + looked + [again], now: now, timeZone: losAngeles)
        #expect(index.firstDay["e"] == "2026-09-30" && index.firstDay["f"] == "2026-09-30")
        #expect(index.restCheckedDays == ["2026-09-28", "2026-09-29", "2026-09-30"])
        let numbers = AttentionNumbers(index: index, now: now, timeZone: losAngeles)
        #expect(numbers.day("2026-09-29").read == 2 && numbers.day("2026-09-29").restChecked)
        #expect(numbers.day("2026-09-30").read == 2 && numbers.day("2026-09-30").restChecked)
    }

    // MARK: - Fixtures

    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let mailID = UUID()

    private static func date(_ text: String) -> Date { AttentionTime.date(text)! }

    /// One card step's line at `time`: `keys` read for the first time, and `seen` read again, each with whether it was shown.
    private static func sorted(_ time: String, keys: [String], shown: Set<String> = [], seen: [String: Bool] = [:],
                               backfilled: Bool = false, in zone: TimeZone? = nil) -> AttentionEvent {
        let at = date(time), runID = UUID()
        let items = keys.map { key in
            AttentionItem(key: key, sourceID: mailID, sourceName: "Example Gmail", kind: "mail", script: "imap-mail__today", runID: runID,
                itemID: key, readAt: at, subject: "Subject \(key) \(time)", preview: "", shown: shown.contains(key))
        }
        let again = seen.sorted { $0.key < $1.key }.map { AttentionEvent.Sorted.Seen(key: $0.key, shown: $0.value) }
        let read = AttentionEvent.Sorted.Source(sourceID: mailID, sourceName: "Example Gmail", script: "imap-mail__today", runID: runID,
            collectedAt: at, arrived: keys.count + seen.count, returned: keys.count + seen.count, truncated: false)
        return AttentionEvent(.sorted(.init(runIDs: [runID], backfilled: backfilled, sources: [read], items: items, seen: again.isEmpty ? nil : again)),
                              at: at, timeZone: zone ?? newYork)
    }

    /// What a Gmail job taught on the screen read of the script's m0, m1 and m2: the Message-ID in m0's headers, a
    /// Gmail link that searches for m1's, and only m2's sender address, subject and date.
    private static let screenCopies = [
        ReadingItem(id: "row-0", title: "Message 0", text: "Sender 0 · Message 0", evidence: "Visible row, headers open",
                    identityKey: "<M0@Example.test>", identityEvidence: "Message-ID <M0@Example.test> in the headers"),
        ReadingItem(id: "row-1", title: "Message 1", text: "Sender 1 · Message 1", evidence: "Visible row",
                    url: "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Am1%40example.test"),
        ReadingItem(id: "row-2", title: "Message 2", text: "Sender 2 · Message 2", evidence: "Visible row",
                    url: "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJWDsKmbLdtPq", identityKey: "sender2@example.test | Message 2 | Sep 30",
                    identityEvidence: "Sender <sender2@example.test>, subject and date shown in the row"),
    ]

    private static func proposal(_ key: String) -> [String: Any] {
        ["observationKey": key, "title": "Reply about the lease", "meaning": "The renewal lapses Friday.",
         "options": [["title": "Draft a reply", "instruction": "Draft a short reply using the saved message.", "mode": "prepare"]]]
    }

    private static func key(in messages: [[String: Any]]) throws -> String {
        let text = ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let split = try #require(text.range(of: "\n\n"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(text[split.upperBound...].utf8)) as? [String: Any])
        return try #require((object["observations"] as? [[String: Any]])?.first?["observationKey"] as? String)
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-sorted-\(UUID())")
        let job = LearnedReadingSource(kind: .mail, name: "Example Gmail", meaning: "My personal inbox",
            scope: "Show anything that needs a reply", script: "imap-mail__today")
        let desktop = DesktopExecutionService(control: ComputerController(), activities: NativeActivityGate())
        let sources: CalendarStore
        let morning: MorningStore
        var file: URL { root.appendingPathComponent("attention/signals.jsonl") }
        var sorted: [AttentionEvent.Sorted] { AttentionLogFile.read(file).events.compactMap(\.sorted) }
        /// The last read of the mail job a card step sorted, which the next read goes back to, as the app works it out.
        var lastSortedRead: Date? {
            ScriptReadWindow.lastRead(sourceID: job.id, runs: sources.runStore.runs,
                                      sorted: Set((morning.workspace.cardGenerations ?? []).flatMap(\.runIDs)))
        }

        init() throws {
            sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
            morning = MorningStore(directory: root.appendingPathComponent("morning"))
            try sources.saveReadingSource(job)
        }

        func ledger(clock: Date = Date()) -> AttentionLedger {
            AttentionLedger(directory: root.appendingPathComponent("attention"), clock: { clock }, timeZone: TimeZone(identifier: "America/New_York")!)
        }

        /// Saves one script read of `count` messages, cut off when more than that arrived, and returns its run.
        @discardableResult
        func read(_ count: Int, arrived: Int? = nil, key: (Int) -> String = { "m\($0)@example.test" }, at: Date = Date(),
                  since: Date? = nil, cutOffSinceLastRead: Int? = nil) throws -> UUID {
            let arrived = arrived ?? count
            let rows: [[String: Any]] = (0..<count).map { index in
                ["key": key(index), "title": "Message \(index)", "from": "Sender \(index) <sender\(index)@example.test>",
                 "received": "2026-09-30T08:\(String(format: "%02d", index % 60)):00+00:00", "unread": true, "tab": "primary",
                 "bulk": index % 3 == 0, "preview": "Preview \(index)", "url": "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Am\(index)"]
            }
            var result: [String: Any] = ["account": "me@example.test", "mailbox": "INBOX",
                "since": since.map { ISO8601DateFormatter().string(from: $0) } ?? "2026-09-29T12:00:00+00:00",
                "arrived": arrived, "returned": count, "truncated": arrived > count, "items": rows]
            if let cutOffSinceLastRead { result["cut_off_since_last_read"] = cutOffSinceLastRead }
            let snapshot = try ScriptReading.snapshot(from: result, request: ReadingReadRequest(source: job), collectedAt: at)
            try sources.saveReadingSnapshot(snapshot)
            return try #require(sources.runStore.runs.first { $0.entries.first?.readingSnapshot?.id == snapshot.id }?.id)
        }

        /// Saves one read of a mail window the person taught, which the test does not count.
        func readATaughtWindow() throws {
            let taught = LearnedReadingSource(kind: .mail, name: "Work mail", meaning: "My work inbox",
                url: "https://mail.example.test/inbox", scope: "Recent unread messages")
            try sources.saveReadingSource(taught)
            try sources.saveReadingSnapshot(ReadingSnapshot(requestID: UUID(), sourceID: taught.id, source: taught, collectedAt: Date(),
                items: [ReadingItem(id: "row-1", title: "Budget review", text: "Budget review is due", evidence: "Visible row")],
                coverage: .complete, accountEvidence: "Current account", sourceEvidence: "Inbox", scopeEvidence: "Recent rows"))
        }

        /// Saves one read of the Gmail inbox by a job taught on the screen, not through a script, and returns the job.
        @discardableResult
        func readTheScreen(_ items: [ReadingItem], name: String = "Gmail inbox – today’s unread", at: Date = Date()) throws
            -> LearnedReadingSource {
            let job = sources.readingSources.first { $0.name == name } ?? LearnedReadingSource(kind: .mail, name: name,
                meaning: "My personal inbox", application: "Google Chrome", url: "https://mail.google.com/mail/u/0/#inbox",
                scope: "Today's unread messages")
            try sources.saveReadingSource(job)
            try sources.saveReadingSnapshot(ReadingSnapshot(requestID: UUID(), sourceID: job.id, source: job, collectedAt: at, items: items,
                coverage: .complete, accountEvidence: "Signed in as me@example.test", sourceEvidence: "Gmail inbox",
                scopeEvidence: "Today's unread messages"))
            return job
        }

        /// What a card step does with every saved run that has no receipt: a card for each of the first `count`
        /// observations, then the receipt.
        @discardableResult
        func sort(showing count: Int, at: Date = Date()) throws -> CardGenerationInput {
            try sort(at: at) { observations in Array(observations.prefix(count)) }
        }

        /// The same, with a card for each observation `carding` picks.
        @discardableResult
        func sort(at: Date = Date(), carding: @escaping (CardObservation) -> Bool) throws -> CardGenerationInput {
            try sort(at: at) { observations in observations.filter(carding) }
        }

        private func sort(at: Date, picking: ([CardObservation]) -> [CardObservation]) throws -> CardGenerationInput {
            let processed = Set((morning.workspace.cardGenerations ?? []).flatMap(\.runIDs))
            let input = CardGenerationInput.saved(in: sources, runID: nil, excluding: processed)
            let proposals = picking(input.observations).map {
                CardProposal(observationKey: $0.id, title: "About \($0.title)", meaning: "It needs a reply.",
                    action: MorningAction(title: "Draft a reply", instruction: "Draft a short reply."))
            }
            try morning.applyCardGeneration(observations: input.observations, proposals: Array(proposals), runIDs: input.runIDs, at: at)
            return input
        }

        func service(_ body: @escaping Client.Body) -> CardGenerationService {
            CardGenerationService(morning: morning, sources: sources, desktop: desktop, config: { Config() }, makeClient: { _ in Client(body) })
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

private extension AttentionEvent {
    var sorted: Sorted? {
        if case .sorted(let sorted) = payload { return sorted }
        return nil
    }
}
