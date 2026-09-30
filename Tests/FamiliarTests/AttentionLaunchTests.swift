import Foundation
import os
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

/// The app reads the ledger off the main thread at launch, and whatever it is told meanwhile waits for the read and is
/// written once, in order. A month of heavy mail loads and counts within a stated budget, because a message read again
/// is written by its key alone, the ledger's own times are read without a formatter, and only the days a screen can
/// show are worked out, once per write. The heavy ledgers are made and measured off the main actor, so other suites'
/// main-actor work goes on meanwhile.
@Suite
struct AttentionLaunchTests {
    @Test func theLaunchReadNeverHoldsUpTheMainThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attention-launch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Self.start.addingTimeInterval(7 * 86_400), file = folder.appendingPathComponent("signals.jsonl")
        try Self.heavyMail(days: 7, into: file)
        let read = AttentionIndex(AttentionLogFile.read(file).events, now: now, timeZone: Self.zone)

        // Whether each read of the file ran on the main thread.
        let onMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let ledger = await MainActor.run {
            let ledger = AttentionLedger(directory: folder, clock: { now }, timeZone: Self.zone, inBackground: true, read: { url, now, zone in
                onMain.withLock { $0.append(Thread.isMainThread) }
                return AttentionIndex(AttentionLogFile.read(url).events, now: now, timeZone: zone)
            })
            // The file is read on another thread, so nothing is known yet and nothing is shown.
            #expect(!ledger.isLoaded && ledger.index.firstDay.isEmpty && ledger.index.startedAt == nil)
            #expect(ledger.numbers.line == nil && ledger.numbers.week == nil && ledger.revision == 0)
            return ledger
        }
        await ledger.untilLoaded()
        // The whole file was read and folded once, off the main thread.
        #expect(onMain.withLock { $0 } == [false])
        await MainActor.run {
            #expect(ledger.isLoaded && ledger.revision == 1 && ledger.error == nil)
            #expect(ledger.index.startedAt == read.startedAt && ledger.index.firstDay == read.firstDay && ledger.index.item == read.item)
            #expect(ledger.index.shownKeys == read.shownKeys && ledger.index.sortedRunIDs == read.sortedRunIDs)
            #expect(ledger.index.labels == read.labels && ledger.index.restCheckedDays == read.restCheckedDays)
            #expect(ledger.index.firstOpened == read.firstOpened)
            #expect(ledger.numbers.line == AttentionNumbers(index: read, now: now, timeZone: Self.zone).line)
            #expect(ledger.index.firstDay.count > 6 * 200 && ledger.numbers.line != nil)
        }
    }

    @Test @MainActor func whatComesInWhileItReadsWaitsAndIsWrittenOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Tuesday morning's read was written; the evening's was saved as Noteling quit, before its line.
        let morning = Self.date("2026-09-29T12:00:00Z"), evening = Self.date("2026-09-30T00:00:00Z")
        let before = fixture.ledger(clock: morning)
        try fixture.read(5, at: morning)
        let first = try fixture.sort(showing: 1, at: morning)
        before.recordSorted(first.observations, runIDs: first.runIDs, runs: fixture.sources.runStore, cards: fixture.morning.cards, at: morning)
        try fixture.read(5, key: { "m\($0 + 3)@example.test" }, at: evening)
        let quit = try fixture.sort(showing: 0, at: evening)
        let written = try Data(contentsOf: fixture.file)

        // At launch the ledger is told everything before its read is in: the missing line, an open, what the person
        // did to the card, and the card coming on screen.
        let launch = Self.date("2026-09-30T12:00:00Z")
        let ledger = fixture.ledger(clock: launch, inBackground: true)
        ledger.watch(fixture.morning)
        ledger.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        ledger.recordOpened(.launcher, route: .folders, desk: 1, wasOpen: false)
        let card = try #require(fixture.morning.cards.first)
        try fixture.morning.setDisposition(cardID: card.id, to: .mine)
        ledger.cardOpened(card)
        #expect(!ledger.isLoaded && ledger.pending.isEmpty && ledger.error == nil)
        #expect(try Data(contentsOf: fixture.file) == written)   // nothing is written before the read is in

        await ledger.untilLoaded()
        let events = AttentionLogFile.read(fixture.file).events
        #expect(events.map(\.type) == [.started, .sorted, .sorted, .opened, .implicit, .engaged])
        #expect(Set(events.map(\.id)).count == events.count)
        // The missing line was worked out against the whole file: dated by its receipt, the two messages the morning
        // held listed by their key alone.
        guard case .sorted(let backfilled) = events[2].payload, case .implicit(let mine) = events[4].payload else {
            Issue.record("The events came in another order.")
            return
        }
        #expect(backfilled.backfilled && backfilled.runIDs == quit.runIDs && events[2].at == evening)
        #expect(backfilled.seen?.map(\.key) == quit.observations.prefix(2).map(\.id) && backfilled.items.count == 3)
        // The card is from a source the ledger reads, so its guess is under its own key, as the rest screen knows it.
        #expect(mine.signal == .mine && mine.key == card.tracking?.key && mine.item.subject == "Message 0" && events[4].at == launch)
        #expect(ledger.index.sortedReads[fixture.job.id]?.count == 2 && ledger.index.firstDay.count == 8)
        #expect(ledger.effective(for: mine.key).state == .guessYes && ledger.index.firstOpened["2026-09-30"] == launch)

        // Told again, it writes nothing more.
        ledger.backfill(receipts: fixture.morning.workspace.cardGenerations ?? [], sources: fixture.sources, cards: fixture.morning.cards)
        #expect(AttentionLogFile.read(fixture.file).events.count == events.count)
    }

    /// The budget, in a debug build: a month of 200 new messages a day, each read twice, is under 9 MB on disk (written
    /// in full at every read it was about 14 MB); reading and folding it, as the app does off the main thread at
    /// launch, takes under 1 s (about 0.16 s here); working out the numbers the screens show takes under 50 ms (about
    /// 3 ms), and asking a hundred times at the same write costs less than working them out ten times.
    @Test func aMonthOfHeavyMailStaysWithinItsBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attention-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Self.start.addingTimeInterval(30 * 86_400 - 3 * 3_600), file = folder.appendingPathComponent("signals.jsonl")   // day 30, 21:00
        try Self.heavyMail(days: 30, into: file)
        let size = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber).intValue

        var index = AttentionIndex(now: now, timeZone: Self.zone)
        let load = Self.fastest { index = AttentionIndex(AttentionLogFile.read(file).events, now: now, timeZone: Self.zone) }
        let today = AttentionTime.day(of: now, in: Self.zone), loaded = index
        let numbers = Self.fastest {
            let worked = AttentionNumbers(index: loaded, now: now, timeZone: Self.zone)
            _ = (worked.line, worked.week, worked.restItems(on: today))
        }
        let ledger = await MainActor.run { AttentionLedger(directory: folder, clock: { now }, timeZone: Self.zone, inBackground: true) }
        await ledger.untilLoaded()
        let asked = await MainActor.run {
            _ = ledger.numbers
            return Self.fastest(1) { for _ in 0..<100 { _ = ledger.numbers.line } }
        }
        print("A month of heavy mail: \(size / 1_024) KB, read and folded in \(Int(load * 1_000)) ms, numbers in \(Int(numbers * 1_000)) ms, "
              + "100 asks in \(Int(asked * 1_000)) ms")

        #expect(index.firstDay.count > 29 * 200 && index.item.count > 14 * 200 && index.item.count < 16 * 200)
        #expect(size < 9_000_000)
        #expect(load < 1)
        #expect(numbers < 0.05)
        #expect(asked < numbers * 10)
    }

    // MARK: - Fixtures

    private static let zone = TimeZone(identifier: "America/Los_Angeles")!
    /// Midnight on July 1, 2026 in Los Angeles.
    private static let start = date("2026-07-01T00:00:00.000-07:00")

    private static func date(_ text: String) -> Date { AttentionTime.date(text)! }

    /// The shortest of `runs` timings of `work`.
    private static func fastest(_ runs: Int = 3, _ work: () -> Void) -> TimeInterval {
        (0..<runs).map { _ in
            let started = Date()
            work()
            return Date().timeIntervalSince(started)
        }.min() ?? 0
    }

    /// `days` of a heavy inbox as the ledger writes it: 200 messages arrive a day and a card step reads the last 24
    /// hours at 08:00 and 20:00, so every message is read twice, in full the first time and by key the second. About
    /// six a read are shown; each is opened and kept, half get a thumb, and each rest is looked through.
    private static func heavyMail(days: Int, into file: URL) throws {
        let sourceID = UUID(), perDay = 200
        let preview = String(String(repeating: "Your order has shipped and is on its way; track it with the link below. ", count: 5)
            .prefix(AttentionItem.previewLimit))
        let card = AttentionCardContext(cardID: UUID(), disposition: .mine, displayDisposition: .mine, optionCount: 2,
            optionModes: [.prepare, .desktop], cardAgeHours: 3.5, userEdited: false, hasPersonalContext: false, createdByRun: nil)
        func key(_ n: Int) -> String { CardObservation.key(sourceID: sourceID, itemKey: "caf\(n)x7yq+zk=hh8_abcdefghijklmnopqr\(n)@mail.gmail.com") }
        let arrived = (0..<days * perDay).map { start.addingTimeInterval(Double($0) * 86_400 / Double(perDay)) }
        var events = [AttentionEvent(.started, at: start, timeZone: zone)], known: Set<Int> = []
        for day in 0..<days {
            for hour in [8, 20] {
                let at = start.addingTimeInterval(Double(day * 24 + hour) * 3_600), runID = UUID()
                let window = arrived.indices.filter { arrived[$0] <= at && arrived[$0] > at.addingTimeInterval(-86_400) }.suffix(200)
                let items = window.filter { !known.contains($0) }.map { n in
                    AttentionItem(key: key(n), sourceID: sourceID, sourceName: "Gmail", kind: "mail", script: "imap-mail__today", runID: runID,
                        itemID: String(repeating: "ab12", count: 16), readAt: at, subject: "Your weekly digest number \(n) from the shop is here",
                        from: "Example Shop <news-\(n % 97)@mail.shop.example.test>", fromName: "Example Shop",
                        address: "news-\(n % 97)@mail.shop.example.test", domain: "mail.shop.example.test",
                        tab: n % 3 == 0 ? "primary" : "promotions", bulk: n % 3 != 0, important: n % 11 == 0, starred: false, unread: true,
                        received: arrived[n], receivedHour: 8, receivedWeekday: 4, ageHours: at.timeIntervalSince(arrived[n]) / 3_600,
                        preview: preview, url: "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Acaf\(n)x7yq%40mail.gmail.com",
                        shown: n % 33 == 0)
                }
                let seen = window.filter { known.contains($0) }.map { AttentionEvent.Sorted.Seen(key: key($0), shown: $0 % 33 == 0) }
                known.formUnion(window)
                events.append(AttentionEvent(.sorted(.init(runIDs: [runID], backfilled: false, sources: [.init(sourceID: sourceID,
                    sourceName: "Gmail", script: "imap-mail__today", runID: runID, collectedAt: at, since: at.addingTimeInterval(-86_400),
                    arrived: window.count, returned: window.count, truncated: false)], items: items, seen: seen.isEmpty ? nil : seen)),
                    at: at, timeZone: zone))
                let looked = at.addingTimeInterval(600)
                events.append(AttentionEvent(.opened(.init(trigger: .launcher, route: "folders", desk: 6)), at: looked, timeZone: zone))
                for (offset, item) in items.filter(\.shown).enumerated() {
                    let then = looked.addingTimeInterval(Double(offset))
                    events.append(AttentionEvent(.engaged(.init(key: item.key, what: .cardOpened, card: card)), at: then, timeZone: zone))
                    events.append(AttentionEvent(.implicit(.init(key: item.key, signal: .mine, item: item, card: card)), at: then, timeZone: zone))
                    if offset % 2 == 0 {
                        events.append(AttentionEvent(.label(.init(key: item.key, value: .yes, weight: 1, prior: .guessYes, via: .card,
                            item: item, card: card)), at: then, timeZone: zone))
                    }
                }
                events.append(AttentionEvent(.restViewed(.init(restDay: AttentionTime.day(of: at, in: zone), count: 190, reachedEnd: true,
                    seconds: 40)), at: looked.addingTimeInterval(100), timeZone: zone))
            }
        }
        try AttentionLogFile(url: file).append(events)
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-launch-\(UUID())")
        let job = LearnedReadingSource(kind: .mail, name: "Example Gmail", meaning: "My personal inbox",
            scope: "Show anything that needs a reply", script: "imap-mail__today")
        let sources: CalendarStore
        let morning: MorningStore
        var file: URL { root.appendingPathComponent("attention/signals.jsonl") }

        init() throws {
            sources = CalendarStore(directory: root.appendingPathComponent("calendar"))
            morning = MorningStore(directory: root.appendingPathComponent("morning"))
            try sources.saveReadingSource(job)
        }

        func ledger(clock: Date, inBackground: Bool = false) -> AttentionLedger {
            AttentionLedger(directory: root.appendingPathComponent("attention"), clock: { clock }, timeZone: AttentionLaunchTests.zone,
                            inBackground: inBackground)
        }

        /// Saves one script read of `count` messages at `at`.
        func read(_ count: Int, key: (Int) -> String = { "m\($0)@example.test" }, at: Date) throws {
            let rows: [[String: Any]] = (0..<count).map { index in
                ["key": key(index), "title": "Message \(index)", "from": "Sender \(index) <sender\(index)@example.test>", "tab": "primary"]
            }
            try sources.saveReadingSnapshot(try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": count, "items": rows],
                request: ReadingReadRequest(source: job), collectedAt: at))
        }

        /// A card step over every saved run without a receipt: a card for each of the first `count` observations.
        func sort(showing count: Int, at: Date) throws -> CardGenerationInput {
            let processed = Set((morning.workspace.cardGenerations ?? []).flatMap(\.runIDs))
            let input = CardGenerationInput.saved(in: sources, runID: nil, excluding: processed)
            let proposals = input.observations.prefix(count).map {
                CardProposal(observationKey: $0.id, title: "About \($0.title)", meaning: "It needs a reply.",
                    action: MorningAction(title: "Draft a reply", instruction: "Draft a short reply."))
            }
            try morning.applyCardGeneration(observations: input.observations, proposals: Array(proposals), runIDs: input.runIDs, at: at)
            return input
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
