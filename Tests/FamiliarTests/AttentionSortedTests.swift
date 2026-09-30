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
        let run = try fixture.read(40, arrived: 64, at: readAt)
        let input = try fixture.sort(showing: 6)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

        let events = AttentionLogFile.read(fixture.file).events
        #expect(events.map(\.type) == [.started, .sorted])
        let sorted = try #require(fixture.sorted.first)
        #expect(sorted.runIDs == [run] && !sorted.backfilled)
        #expect(sorted.items.count == 40 && sorted.items.filter(\.shown).count == 6)
        #expect(sorted.sources == [.init(sourceID: fixture.job.id, sourceName: "Example Gmail", script: "imap-mail__today", runID: run,
            collectedAt: readAt, since: Self.date("2026-09-29T12:00:00Z"), arrived: 64, returned: 40, truncated: true)])
        #expect(ledger.index.sortedRunIDs == [run] && ledger.index.sortedReads[fixture.job.id]?.map(\.arrived) == [64])
        #expect(ledger.revision == 2 && ledger.error == nil)   // one write for `started`, one for the line
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
        let script = try fixture.read(3, at: now)
        try saveOthers(now)
        let mixed = try fixture.sort(showing: 5)   // every item gets a card, the taught and calendar ones too
        #expect(mixed.runIDs.count == 3 && mixed.observations.count == 5)
        ledger.recordSorted(mixed.observations, runIDs: mixed.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)

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

    @Test func aJobRemovedWhileItsStepRanIsNeverBackfilled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
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
        let written = try Data(contentsOf: fixture.file)

        fixture.ledger().backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(try Data(contentsOf: fixture.file) == written && fixture.sorted.isEmpty)
    }

    @Test func backfillClosesTheCrashWindowButNeverReachesBeforeTheStart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let early = Self.date("2026-09-29T13:00:00Z"), start = Self.date("2026-09-29T20:00:00Z"), late = Self.date("2026-09-30T13:00:00.123Z")
        try fixture.read(3, at: early)
        try fixture.sort(showing: 1, at: early)   // a receipt from before the ledger existed

        let ledger = fixture.ledger(clock: start)
        ledger.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(fixture.sorted.isEmpty)

        // Saved, but Noteling quit before its line was written.
        try fixture.read(4, key: { "later-\($0)@example.test" }, at: late)
        let missed = try fixture.sort(showing: 2, at: late)
        let restarted = fixture.ledger(clock: late.addingTimeInterval(3_600))
        restarted.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)

        let events = AttentionLogFile.read(fixture.file).events
        #expect(events.map(\.type) == [.started, .sorted] && events[0].at == start)
        #expect(events[1].at == late && events[1].day == "2026-09-30")   // the receipt's own time, not the launch's
        let sorted = try #require(fixture.sorted.first)
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
        ledger.recordOpened(.launcher, route: .folders, desk: 2, wasOpen: false)
        // Its line is in the file, so the index has it too, and nothing waits to be written again.
        #expect(AttentionLogFile.read(fixture.file).events.map(\.type) == [.started, .opened])
        #expect(ledger.index.firstOpened["2026-09-30"] != nil && ledger.pending.isEmpty && ledger.error == nil && ledger.revision == 2)

        ledger.file.sync = { fsync($0) }
        ledger.recordOpened(.chat, route: .folders, desk: 2, wasOpen: false)
        #expect(AttentionLogFile.read(fixture.file).events.map(\.type) == [.started, .opened, .opened])
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

    @Test func aFailedWriteIsShownAndNeverThrown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.file.deletingLastPathComponent()
        try Data("not a folder".utf8).write(to: folder)
        let ledger = fixture.ledger()
        #expect(ledger.error == "Couldn’t save the attention log (error \(EEXIST)).")
        #expect(ledger.index.startedAt == nil && ledger.revision == 0)

        try fixture.read(2)
        let first = try fixture.sort(showing: 1)
        ledger.recordSorted(first.observations, runIDs: first.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        #expect(ledger.index.sortedRunIDs.isEmpty && ledger.error != nil)   // nothing joins the index that is not on disk
        #expect(ledger.pending.map(\.type) == [.started, .sorted])

        // Once the folder can be made, the start and the line that waited are written ahead of the next one, and the
        // error clears.
        try FileManager.default.removeItem(at: folder)
        try fixture.read(3, key: { "later-\($0)@example.test" })
        let next = try fixture.sort(showing: 0)
        ledger.recordSorted(next.observations, runIDs: next.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards)
        #expect(AttentionLogFile.read(fixture.file).events.map(\.type) == [.started, .sorted, .sorted])
        #expect(fixture.sorted.map(\.runIDs) == [first.runIDs, next.runIDs] && ledger.error == nil && ledger.revision == 1)
        #expect(ledger.pending.isEmpty && ledger.index.sortedRunIDs == Set(first.runIDs + next.runIDs))
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
        func read(_ count: Int, arrived: Int? = nil, key: (Int) -> String = { "m\($0)@example.test" }, at: Date = Date()) throws -> UUID {
            let arrived = arrived ?? count
            let rows: [[String: Any]] = (0..<count).map { index in
                ["key": key(index), "title": "Message \(index)", "from": "Sender \(index) <sender\(index)@example.test>",
                 "received": "2026-09-30T08:\(String(format: "%02d", index % 60)):00+00:00", "unread": true, "tab": "primary",
                 "bulk": index % 3 == 0, "preview": "Preview \(index)", "url": "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Am\(index)"]
            }
            let result: [String: Any] = ["account": "me@example.test", "mailbox": "INBOX", "since": "2026-09-29T12:00:00+00:00",
                "arrived": arrived, "returned": count, "truncated": arrived > count, "items": rows]
            let snapshot = try ScriptReading.snapshot(from: result, request: ReadingReadRequest(source: job), collectedAt: at)
            try sources.saveReadingSnapshot(snapshot)
            return try #require(sources.runStore.runs.first { $0.entries.first?.readingSnapshot?.id == snapshot.id }?.id)
        }

        /// What a card step does with every saved run that has no receipt: a card for each of the first `count`
        /// observations, then the receipt.
        @discardableResult
        func sort(showing count: Int, at: Date = Date()) throws -> CardGenerationInput {
            let processed = Set((morning.workspace.cardGenerations ?? []).flatMap(\.runIDs))
            let input = CardGenerationInput.saved(in: sources, runID: nil, excluding: processed)
            let proposals = input.observations.prefix(count).map {
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
