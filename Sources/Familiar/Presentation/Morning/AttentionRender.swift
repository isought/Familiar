import AppKit
import SwiftUI

/// The attention test on the card face and on its own screens, rendered from a fictional week of an example inbox. The
/// render fails when the thumbs move anything below a card's header line or grow past one small line.
extension MorningRender {
    @MainActor static func renderAttention(fixtures: URL, directory: URL) throws {
        let week = try AttentionWeek(directory: fixtures.appendingPathComponent("attention-week"))
        let navigation = MorningNavigation()
        let size = NSSize(width: 650, height: MorningPanelController.preferredHeight(for: .card(UUID())))
        func save(_ title: String, as name: String, attention: AttentionLedger?, in folder: URL = directory) throws -> URL {
            navigation.route = .card(try week.card(title).id)
            week.ledger.clock = { AttentionWeek.time("2026-09-30T09:30:00") }
            let url = folder.appendingPathComponent(name)
            try image(MorningFilesView(store: week.store, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
                                       discussCard: { _ in }, attention: attention), size: size, to: url)
            return url
        }
        let lease = "Dana needs the signed lease by Friday"
        let without = try save(lease, as: "attention-card-without-thumbs.png", attention: nil, in: fixtures)
        let unlabeled = try save(lease, as: "attention-card-unlabeled.png", attention: week.ledger)
        try checkThumbsStayOnTheHeaderLine(without: without, with: unlabeled, size: size)
        _ = try save("Your package is delayed", as: "attention-card-guessed-no.png", attention: week.ledger)
        _ = try save("Dr. Lee’s office needs your forms by Thursday", as: "attention-card-strong-yes.png", attention: week.ledger)
        week.ledger.beginExplaining(try week.card(lease).tracking?.key ?? "")
        _ = try save(lease, as: "attention-card-explaining.png", attention: week.ledger)
        week.ledger.cancelExplaining()
        // A second copy of the week, so the labels the size check gives leave the rendered week as it was.
        try checkThumbSizes(week: try AttentionWeek(directory: fixtures.appendingPathComponent("attention-sizes")), title: lease)
        try renderAttentionScreens(week: week, directory: directory)
        try renderUnsaved(fixtures: fixtures, directory: directory)
    }

    /// The folders screen when a file stands where the ledger's folder goes, so the first read's line couldn't be
    /// saved: there is no line and no thumbs yet, and the failure is said in the line's place.
    @MainActor private static func renderUnsaved(fixtures: URL, directory: URL) throws {
        let root = fixtures.appendingPathComponent("attention-unsaved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Not a folder.".utf8).write(to: root.appendingPathComponent("attention"))
        let at = AttentionWeek.time("2026-09-30T08:05:00")
        let sources = CalendarStore(directory: root.appendingPathComponent("sources"))
        let store = MorningStore(directory: root.appendingPathComponent("morning"))
        let ledger = AttentionLedger(directory: root.appendingPathComponent("attention"), clock: { at }, timeZone: AttentionWeek.zone)
        let job = LearnedReadingSource(kind: .mail, name: "Example Gmail", meaning: "My personal inbox · fictional example",
            scope: "Show what needs me: replies, deadlines, bills and appointments.", script: "imap-mail__today")
        try sources.saveReadingSource(job)
        let rows: [[String: Any]] = [
            ["key": "lease@mail.example.test", "title": "Lease renewal: sign by Friday", "from": "Dana Ruiz <dana@rent.example.test>",
             "tab": "primary", "preview": "Please sign the renewal by Friday so the rent stays the same."],
            ["key": "sale@mail.example.test", "title": "50% off everything", "from": "Example Shop <deals@shop.example.test>",
             "tab": "promotions", "bulk": true, "preview": "This weekend only."],
        ]
        try sources.saveReadingSnapshot(try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": rows.count, "items": rows],
            request: ReadingReadRequest(source: job, requestedAt: at), collectedAt: at))
        let input = CardGenerationInput.saved(in: sources, runID: nil, excluding: [])
        guard let lease = input.observations.first(where: { $0.title.hasPrefix("Lease") }) else {
            throw AttentionRenderFailure("The unsaved read has no lease.")
        }
        try store.applyCardGeneration(observations: input.observations, proposals: [CardProposal(observationKey: lease.id,
            title: "Dana needs the signed lease by Friday", meaning: "The renewal lapses Friday; signing keeps this rent.",
            action: MorningAction(title: "Draft a reply", instruction: "Draft a reply to the fictional message. Do not send it."))],
            runIDs: input.runIDs, at: at)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: sources.runStore, cards: store.cards)
        guard ledger.error != nil, ledger.numbers.line == nil else { throw AttentionRenderFailure("The read that can’t be saved was saved.") }
        try image(MorningFilesView(store: store, navigation: MorningNavigation(), close: {}, filed: {}, handoff: { _ in },
                                   calendarSources: sources, discussCard: { _ in }, attention: ledger),
                  size: NSSize(width: 650, height: MorningPanelController.preferredHeight(for: .folders)),
                  to: directory.appendingPathComponent("attention-daily-line-unsaved.png"))
    }

    /// The daily line on the folders screen, today's rest, the week against the pass bar, and the rest again after a
    /// miss. The pack was opened every morning read, and every rest was looked through but Monday's, so the miss bar
    /// waits on Monday; the week is drawn before the miss, so it stays clean.
    @MainActor private static func renderAttentionScreens(week: AttentionWeek, directory: URL) throws {
        let ledger = week.ledger, today = "2026-09-30"
        week.visit(leaving: ["2026-09-28", today])
        ledger.clock = { AttentionWeek.time("2026-09-30T09:30:00") }
        let navigation = MorningNavigation()
        func save(_ name: String, _ route: MorningNavigation.Route, height: CGFloat? = nil) throws {
            navigation.route = route
            try image(MorningFilesView(store: week.store, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
                                       calendarSources: week.sources, discussCard: { _ in }, attention: ledger),
                      size: NSSize(width: 650, height: height ?? MorningPanelController.preferredHeight(for: route)),
                      to: directory.appendingPathComponent(name))
        }
        try save("attention-daily-line.png", .folders)
        // The whole of today's rest, as far as scrolling reaches, down to the line that checks it.
        try save("attention-rest.png", .attention(.rest(day: today)), height: 2_300)
        ledger.restViewed(day: today, count: ledger.numbers.day(today).restCount, reachedEnd: true, seconds: 48)
        try save("attention-week.png", .attention(.week))
        guard let statement = ledger.numbers.restItems(on: today).items.first(where: { $0.subject == "Your October statement is ready" }) else {
            throw AttentionRenderFailure("Today’s rest has no statement to miss.")
        }
        ledger.miss(key: statement.key)
        try save("attention-rest-missed.png", .attention(.rest(day: today)))
        if let error = ledger.error { throw AttentionRenderFailure(error) }
    }

    /// Everything the thumbs add must fit a small box on the trailing side of the card's header line, so the title,
    /// the meaning, the options, the quiet row and the original links stay exactly where they were, pixel for pixel.
    @MainActor private static func checkThumbsStayOnTheHeaderLine(without: URL, with: URL, size: NSSize) throws {
        guard let plain = NSBitmapImageRep(data: try Data(contentsOf: without)),
              let labeled = NSBitmapImageRep(data: try Data(contentsOf: with)),
              plain.pixelsWide == labeled.pixelsWide, plain.pixelsHigh == labeled.pixelsHigh,
              plain.bitsPerPixel == labeled.bitsPerPixel, plain.bytesPerRow == labeled.bytesPerRow,
              let a = plain.bitmapData, let b = labeled.bitmapData else {
            throw AttentionRenderFailure("The card renders with and without thumbs could not be compared.")
        }
        let bytes = plain.bitsPerPixel / 8
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<plain.pixelsHigh {
            let row = y * plain.bytesPerRow
            guard memcmp(a + row, b + row, plain.pixelsWide * bytes) != 0 else { continue }
            for x in 0..<plain.pixelsWide where memcmp(a + row + x * bytes, b + row + x * bytes, bytes) != 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { throw AttentionRenderFailure("The thumbs are missing from the card.") }
        let scale = CGFloat(plain.pixelsWide) / size.width
        let box = NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                         width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        // The panel's header and divider end 55pt down and the card is inset 23pt, so its header line starts at 78pt;
        // the title's letters start below 110pt.
        guard box.width <= 150, box.height <= 28, box.minX >= size.width / 2, box.minY >= 55, box.maxY <= 110 else {
            throw AttentionRenderFailure("The thumbs changed the card outside the trailing side of its header line: \(box).")
        }
        print("thumbs changed only \(Int(box.width))x\(Int(box.height))pt at \(Int(box.minX)),\(Int(box.minY)) on the card's header line")
    }

    /// In every state, with or without an explanation, the thumbs and their hit areas stay within 64×18pt.
    @MainActor private static func checkThumbSizes(week: AttentionWeek, title: String) throws {
        let store = week.store, ledger = week.ledger, measured = try week.card(title), id = measured.id
        guard let key = measured.tracking?.key else { throw AttentionRenderFailure("The size check has no card.") }
        func card() -> MorningCard? { store.cards.first { $0.id == id } }
        func tap(_ thumb: AttentionLabels.Thumb) { ledger.tapThumb(key: key, card: card(), thumb: thumb, via: .card) }
        let states: [(AttentionPrior, () throws -> Void)] = [
            (.notSet, {}), (.guessYes, { try store.setDisposition(cardID: id, to: .mine) }),
            (.guessNo, { try store.setDisposition(cardID: id, to: .ignored) }), (.yes, { tap(.up) }), (.strongYes, { tap(.up) }),
            (.no, { tap(.down) }), (.strongNo, { tap(.down) })
        ]
        var largest = NSSize.zero
        for explained in [false, true] {
            if explained { ledger.explain(key: key, card: card(), text: "Only measured.", via: .card) }
            for (state, reach) in states {
                try reach()
                guard ledger.effective(for: key).state == state, let current = card() else {
                    throw AttentionRenderFailure("The size check could not reach \(state.rawValue).")
                }
                // The layout leaves out the overhang, so it is added back to measure the hit areas.
                var fitting = NSHostingView(rootView: AttentionThumbs(ledger: ledger, card: current)).fittingSize
                fitting.height += 2 * AttentionThumbs.overhang
                guard fitting.width > 0, fitting.width <= 64, fitting.height <= 18 else {
                    throw AttentionRenderFailure("The thumbs grew to \(fitting.width)x\(fitting.height)pt when \(state.rawValue)\(explained ? ", explained" : "").")
                }
                largest = NSSize(width: max(largest.width, fitting.width), height: max(largest.height, fitting.height))
            }
            tap(.down)   // clears the thumb; taking back the Ignore leaves no label
            try store.setDisposition(cardID: id, to: .unreviewed)
        }
        print("thumbs measured at most \(Int(largest.width))x\(Int(largest.height))pt in all \(states.count) states, with and without words")
    }
}

private struct AttentionRenderFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A fictional week of an example inbox, read by the mail script each morning and sorted by the card step, with what
/// the person did to the cards it showed. Thu Sep 24 to Wed Sep 30, 2026 in New York; Saturday was not read. Every
/// sender, address and message is made up.
@MainActor private struct AttentionWeek {
    static let zone = TimeZone(identifier: "America/New_York")!
    let sources: CalendarStore
    let store: MorningStore
    let ledger: AttentionLedger
    let job: LearnedReadingSource

    init(directory: URL) throws {
        sources = CalendarStore(directory: directory.appendingPathComponent("sources"))
        store = MorningStore(directory: directory.appendingPathComponent("morning"))
        let start = Self.time(Self.mornings[0].at)
        ledger = AttentionLedger(directory: directory.appendingPathComponent("attention"), clock: { start }, timeZone: Self.zone)
        job = LearnedReadingSource(kind: .mail, name: "Example Gmail", meaning: "My personal inbox · fictional example",
            scope: "Show what needs me: replies, deadlines, bills and appointments.", script: "imap-mail__today")
        try sources.saveReadingSource(job)
        ledger.watch(store)
        for (day, morning) in Self.mornings.enumerated() { try read(morning, day: day) }
        if let error = ledger.error { throw AttentionRenderFailure(error) }
    }

    /// The person opened the pack as each morning's read came in, and later looked through each day's rest to its
    /// end, except on `unchecked` days.
    func visit(leaving unchecked: Set<String>) {
        for morning in Self.mornings {
            let at = Self.time(morning.at), day = String(morning.at.prefix(10))
            ledger.clock = { at }
            ledger.recordOpened(.launcher, route: .folders, desk: store.cards.filter { $0.displayDisposition == .unreviewed }.count, wasOpen: false)
            guard !unchecked.contains(day) else { continue }
            ledger.clock = { at.addingTimeInterval(40 * 60) }
            ledger.restViewed(day: day, count: ledger.numbers.day(day).restCount, reachedEnd: true, seconds: 52)
        }
    }

    func card(_ title: String) throws -> MorningCard {
        guard let card = store.cards.first(where: { $0.title == title }) else { throw AttentionRenderFailure("No card “\(title)”.") }
        return card
    }

    /// A local time in New York, "yyyy-MM-ddTHH:mm:ss".
    static func time(_ local: String) -> Date { ISO8601DateFormatter().date(from: local + "-04:00")! }

    /// One morning: the script reads the last 24 hours, the card step shows a few, and the person acts on some.
    private func read(_ morning: Morning, day: Int) throws {
        let at = Self.time(morning.at)
        let iso = ISO8601DateFormatter()
        let stamp = morning.at.prefix(10).replacingOccurrences(of: "-", with: "")
        var mail = morning.shown.map(\.mail)
        mail += (0..<2).map { Self.personal[(day * 2 + $0) % Self.personal.count] }
        mail += (0..<6).map { Self.updates[(day * 6 + $0) % Self.updates.count] }
        mail += (0..<(morning.arrived - mail.count)).map { Self.lists[(day * 5 + $0) % Self.lists.count] }
        let rows: [[String: Any]] = mail.enumerated().map { index, message in
            // Spread over the window, so the shown ones are not all the newest.
            let received = at.addingTimeInterval(-Double((index * 19) % morning.arrived + 1) * 25 * 60)
            return ["key": "\(stamp)-\(index)@mail.example.test", "title": message.subject, "from": message.from,
                    "received": iso.string(from: received), "unread": index % 3 != 0, "starred": false, "tab": message.tab,
                    "important": message.important, "bulk": message.bulk, "preview": message.preview,
                    "url": "https://mail.example.test/message/\(stamp)-\(index)"]
        }
        // Each read reaches a little over a day back, so mornings read at different times still meet; only the
        // Saturday that was not read leaves mail unread.
        let result: [String: Any] = ["account": "alex@example.test", "server": "imap.example.test", "mailbox": "INBOX",
            "since": iso.string(from: at.addingTimeInterval(-26 * 3_600)), "arrived": morning.arrived,
            "returned": morning.arrived, "truncated": false, "items": rows]
        let snapshot = try ScriptReading.snapshot(from: result, request: ReadingReadRequest(source: job, requestedAt: at), collectedAt: at)
        try sources.saveReadingSnapshot(snapshot)
        guard let run = sources.runStore.runs.first(where: { $0.entries.contains { $0.readingSnapshot?.id == snapshot.id } }) else {
            throw AttentionRenderFailure("The \(stamp) read was not saved.")
        }
        let input = CardGenerationInput.saved(in: sources, runID: run.id, excluding: [])
        let proposals = morning.shown.enumerated().map { index, shown in
            CardProposal(observationKey: CardObservation.key(sourceID: job.id, itemKey: "\(stamp)-\(index)@mail.example.test"),
                title: shown.title, meaning: shown.meaning,
                action: MorningAction(title: shown.options[0], instruction: "\(shown.options[0]) from the fictional message. Do not send it."),
                alternatives: shown.options.dropFirst().map { MorningAction(title: $0, instruction: "\($0) from the fictional message.") })
        }
        ledger.clock = { at }
        try store.applyCardGeneration(observations: input.observations, proposals: proposals, runIDs: input.runIDs, at: at)
        ledger.recordSorted(input.observations, runIDs: input.runIDs, runs: sources.runStore, cards: store.cards, at: at)
        for (index, shown) in morning.shown.enumerated() {
            let key = CardObservation.key(sourceID: job.id, itemKey: "\(stamp)-\(index)@mail.example.test")
            guard let id = store.cards.first(where: { $0.tracking?.key == key })?.id else { continue }
            for (step, act) in shown.did.enumerated() {
                ledger.clock = { at.addingTimeInterval(Double(index * 4 + step + 2) * 60) }
                let card = store.cards.first { $0.id == id }
                switch act {
                case .option:
                    let work = try store.enqueue(cardID: id)
                    try store.updateWork(id: work.id, status: .running)
                    try store.updateWork(id: work.id, status: .completed, result: "A fictional result.")
                case .mine: try store.setDisposition(cardID: id, to: .mine)
                case .ignore: try store.setDisposition(cardID: id, to: .ignored)
                case .handled: try store.setCardResolution(cardID: id, resolved: true)
                case .up: ledger.tapThumb(key: key, card: card, thumb: .up, via: .card)
                case .down: ledger.tapThumb(key: key, card: card, thumb: .down, via: .card)
                case .explain(let text): ledger.explain(key: key, card: card, text: text, via: .card)
                }
            }
        }
    }

    // MARK: - The fictional inbox

    private struct Mail {
        var from: String
        var subject: String
        var preview: String
        var tab = "primary"
        var important = false
        var bulk = false
    }

    private enum Act { case option, mine, ignore, handled, up, down, explain(String) }

    private struct Shown {
        var mail: Mail
        var title: String
        var meaning: String
        var options: [String]
        var did: [Act] = []
    }

    private struct Morning {
        /// Local time of the read.
        var at: String
        var arrived: Int
        var shown: [Shown]
    }

    private static let mornings = [
        Morning(at: "2026-09-24T07:58:00", arrived: 42, shown: [
            Shown(mail: Mail(from: "Priya Shah <priya@studio.example.test>", subject: "Can you look at the draft contract?",
                             preview: "I’ve attached the revised terms. I need your notes by Monday.", important: true),
                  title: "Priya needs your notes on the contract by Monday", meaning: "The studio signs Tuesday; your notes shape the terms.",
                  options: ["Summarize the changes", "Draft notes for Priya"], did: [.option]),
            Shown(mail: Mail(from: "Oak Street Dental <frontdesk@oakdental.example.test>", subject: "Confirm your cleaning on Oct 2",
                             preview: "Reply C to confirm, or call us to reschedule."),
                  title: "Your dental cleaning is Oct 2 at 10:30", meaning: "Confirming keeps the slot; they release it tomorrow.",
                  options: ["Draft a confirmation", "Add it to the calendar"], did: [.mine]),
            Shown(mail: Mail(from: "City Water <billing@citywater.example.test>", subject: "Your bill is past due",
                             preview: "A late fee applies after September 28.", tab: "updates", important: true),
                  title: "The water bill is past due", meaning: "A $15 late fee lands Monday unless it’s paid.",
                  options: ["Open the payment page"], did: [.handled]),
            Shown(mail: Mail(from: "Sam Ortiz <sam@example.test>", subject: "Dinner Saturday?",
                             preview: "Are you still up for the new place on 5th?"),
                  title: "Sam is asking about dinner Saturday", meaning: "He needs a yes or no to book the table.",
                  options: ["Draft a reply"], did: [.up])
        ]),
        Morning(at: "2026-09-25T08:20:00", arrived: 39, shown: [
            Shown(mail: Mail(from: "Northwind HR <hr@northwind.example.test>", subject: "Open enrollment closes Oct 1",
                             preview: "Review your benefits before Wednesday.", important: true),
                  title: "Benefits enrollment closes Wednesday", meaning: "Missing it keeps last year’s plan for another year.",
                  options: ["List what changed", "Add a reminder"], did: [.option]),
            Shown(mail: Mail(from: "Maple Elementary <office@maple.example.test>", subject: "Field trip form due Monday",
                             preview: "Please sign and return the attached form."),
                  title: "Jamie’s field trip form is due Monday", meaning: "Without it Jamie stays at school that day.",
                  options: ["Draft a reply with the form"], did: [.mine]),
            Shown(mail: Mail(from: "Leo Park <leo@example.test>", subject: "Invoice #1042",
                             preview: "Attached is the invoice for September’s work."),
                  title: "Leo sent September’s invoice", meaning: "It’s due in 15 days; paying on time keeps his rate.",
                  options: ["Summarize the invoice"], did: [.ignore]),
            Shown(mail: Mail(from: "Parcel Example <track@parcel.example.test>", subject: "Signature required for delivery",
                             preview: "We’ll try again Saturday between 9 and 1.", tab: "updates"),
                  title: "A package needs your signature Saturday", meaning: "If no one is home, it goes back to the depot.",
                  options: ["Ask to leave it with a neighbor"], did: [.handled])
        ]),
        Morning(at: "2026-09-27T09:02:00", arrived: 45, shown: [
            Shown(mail: Mail(from: "Grace Kim <grace@example.test>", subject: "Photos from the reunion",
                             preview: "Here’s the album. The link expires Friday."),
                  title: "Grace shared the reunion photos", meaning: "The album link expires Friday.",
                  options: ["Save the album link"], did: [.mine]),
            Shown(mail: Mail(from: "Example Air <checkin@air.example.test>", subject: "Check in for your flight to Denver",
                             preview: "Check-in is now open for Tuesday’s flight.", tab: "updates", important: true),
                  title: "Check-in is open for Tuesday’s Denver flight", meaning: "Checking in now keeps your aisle seat.",
                  options: ["Open check-in"], did: [.option]),
            Shown(mail: Mail(from: "Harbor Insurance <claims@harbor.example.test>", subject: "We need one more document",
                             preview: "Please send the repair estimate to continue your claim.", important: true),
                  title: "Your insurance claim needs one more document", meaning: "The claim waits until they have the repair estimate.",
                  options: ["Find the repair estimate", "Draft a reply"], did: [.up, .up]),
            Shown(mail: Mail(from: "Mia Chen <mia@example.test>", subject: "Can you cover Thursday?",
                             preview: "I need someone for my Thursday shift."),
                  title: "Mia asks if you can cover her Thursday shift", meaning: "She needs to know tonight to find someone else.",
                  options: ["Draft a reply"], did: [.ignore])
        ]),
        Morning(at: "2026-09-28T08:11:00", arrived: 51, shown: [
            Shown(mail: Mail(from: "Riverside Library <notices@library.example.test>", subject: "Your hold is ready",
                             preview: "Pick it up by Friday.", tab: "updates"),
                  title: "Your library hold is ready", meaning: "It goes back on the shelf after Friday.",
                  options: ["Add pickup to the calendar"], did: [.handled]),
            Shown(mail: Mail(from: "Tom Becker <tom@work.example.test>", subject: "Budget numbers for Q4?",
                             preview: "Could you send your Q4 numbers before Thursday?", important: true),
                  title: "Tom needs your Q4 budget numbers", meaning: "He presents to the board Thursday.",
                  options: ["Draft the numbers summary", "Ask what format he wants"],
                  did: [.option, .up, .explain("Tom always needs these a day early.")]),
            Shown(mail: Mail(from: "Example Bank <alerts@bank.example.test>", subject: "Unusual sign-in attempt",
                             preview: "We noticed a sign-in from a new device.", tab: "updates", important: true),
                  title: "Your bank flagged an unusual sign-in", meaning: "If it wasn’t you, lock the card today.",
                  options: ["Open the security page"], did: [.mine]),
            Shown(mail: Mail(from: "Nina Alvarez <nina@example.test>", subject: "Recommendation letter",
                             preview: "Would you write me a recommendation?"),
                  title: "Nina asked for a recommendation letter", meaning: "Her application closes Oct 10.",
                  options: ["Draft a first version"])
        ]),
        Morning(at: "2026-09-29T07:48:00", arrived: 44, shown: [
            Shown(mail: Mail(from: "Coach Reyes <coach@league.example.test>", subject: "Practice moved to 5:30",
                             preview: "Thursday’s practice starts at 5:30 this week."),
                  title: "Soccer practice moved to 5:30 Thursday", meaning: "Pickup is an hour later than usual.",
                  options: ["Update the calendar"], did: [.option]),
            Shown(mail: Mail(from: "Example Energy <billing@energy.example.test>", subject: "Your rate changes Nov 1",
                             preview: "Lock in a fixed plan by Oct 15.", tab: "updates"),
                  title: "Your electricity rate goes up Nov 1", meaning: "Choosing the fixed plan by Oct 15 avoids it.",
                  options: ["Compare the plans"], did: [.mine]),
            Shown(mail: Mail(from: "Omar Haddad <omar@example.test>", subject: "Contract signed!",
                             preview: "We’re in. Can we kick off this week?"),
                  title: "Omar’s contract is signed", meaning: "He’d like the kickoff this week.",
                  options: ["Propose kickoff times"], did: [.up, .up]),
            Shown(mail: Mail(from: "Pet Clinic <care@vet.example.test>", subject: "Rex is due for his shots",
                             preview: "Book a visit before his boarding stay."),
                  title: "Rex is due for his vaccines", meaning: "Boarding next month needs them on record.",
                  options: ["Book a visit"], did: [.ignore]),
            Shown(mail: Mail(from: "Ava Brooks <ava@example.test>", subject: "Quick question about Friday",
                             preview: "Do you have the agenda for Friday?"),
                  title: "Ava needs the Friday agenda", meaning: "She prints the handouts tomorrow morning.",
                  options: ["Draft the agenda"], did: [.down])
        ]),
        Morning(at: "2026-09-30T09:00:00", arrived: 40, shown: [
            Shown(mail: Mail(from: "Dana Ruiz <dana@rent.example.test>", subject: "Lease renewal: sign by Friday",
                             preview: "Please sign the renewal by Friday so we can keep this rate.", important: true),
                  title: "Dana needs the signed lease by Friday", meaning: "The renewal lapses Friday; signing keeps this rent.",
                  options: ["Draft a reply", "Add Friday to calendar"]),
            Shown(mail: Mail(from: "Shop Example <orders@shop.example.test>", subject: "Your package is delayed",
                             preview: "Your order now arrives Monday.", tab: "updates"),
                  title: "Your package is delayed", meaning: "It now arrives Monday, after the party.",
                  options: ["Ask for a refund", "Find it in a store nearby"], did: [.ignore]),
            Shown(mail: Mail(from: "Dr. Lee’s office <office@drlee.example.test>", subject: "Forms before your visit",
                             preview: "Please complete the attached forms by Thursday.", important: true),
                  title: "Dr. Lee’s office needs your forms by Thursday", meaning: "Without them the visit moves a week.",
                  options: ["Fill in what I know", "Add Thursday to calendar"],
                  did: [.up, .up, .explain("Missing it pushes my visit back a week.")]),
            Shown(mail: Mail(from: "Jordan Wu <jordan@work.example.test>", subject: "Slides for tomorrow",
                             preview: "Can you send your two slides tonight?"),
                  title: "Jordan needs your two slides by tonight", meaning: "The deck goes to the client at 9 tomorrow.",
                  options: ["Draft the two slides"], did: [.option]),
            Shown(mail: Mail(from: "County Clerk <jury@county.example.test>", subject: "Jury duty summons",
                             preview: "You are summoned for October 19.", important: true),
                  title: "You’re summoned for jury duty Oct 19", meaning: "Postponing needs a reply within 10 days.",
                  options: ["Draft a postponement request"], did: [.mine]),
            Shown(mail: Mail(from: "Example Credit Union <alerts@cu.example.test>", subject: "Payment received",
                             preview: "Your car payment went through.", tab: "updates"),
                  title: "Your car payment went through", meaning: "Nothing to do; the next one is Oct 30.",
                  options: ["Add an Oct 30 reminder"], did: [.handled])
        ])
    ]

    /// Messages from people that no card step showed.
    private static let personal = [
        Mail(from: "Lena Fox <lena@example.test>", subject: "Re: book club pick", preview: "I vote for the mystery one."),
        Mail(from: "Ben Cole <ben@example.test>", subject: "Carpool next week", preview: "I can drive Monday and Wednesday."),
        Mail(from: "Kai Moreno <kai@example.test>", subject: "Thanks for yesterday!", preview: "That was really helpful."),
        Mail(from: "Mom <mom@family.example.test>", subject: "Look at the garden", preview: "The tomatoes finally came in."),
        Mail(from: "Ravi Iyer <ravi@example.test>", subject: "Quick favor", preview: "Could you send me that recipe?"),
        Mail(from: "Bright Roofing <quotes@roofing.example.test>", subject: "Your roofing quote", preview: "Here’s the estimate we discussed."),
        Mail(from: "Ellie Tran <ellie@work.example.test>", subject: "Notes from today’s sync", preview: "Notes are attached. Nothing urgent."),
        Mail(from: "Block Association <hello@block.example.test>", subject: "Street fair Saturday", preview: "Come by the table on Elm.")
    ]

    /// Receipts, statements and notices.
    private static let updates = [
        Mail(from: "Example Bank <statements@bank.example.test>", subject: "Your October statement is ready",
             preview: "Your statement is ready to view.", tab: "updates", important: true),
        Mail(from: "Corner Coffee <receipts@coffee.example.test>", subject: "Your receipt from Corner Coffee", preview: "Thanks for stopping by.", tab: "updates"),
        Mail(from: "Example Books <orders@books.example.test>", subject: "Your order has shipped", preview: "It arrives Thursday.", tab: "updates"),
        Mail(from: "Example Account <security@account.example.test>", subject: "Your password was changed", preview: "If this was you, no action is needed.", tab: "updates"),
        Mail(from: "Example Ride <receipts@ride.example.test>", subject: "Your ride receipt", preview: "Trip on Tuesday evening.", tab: "updates"),
        Mail(from: "Riverside Library <notices@library.example.test>", subject: "A book is due Friday", preview: "Renew online if you need more time.", tab: "updates"),
        Mail(from: "Example Device <reports@device.example.test>", subject: "Your weekly screen time report", preview: "Down 8% from last week.", tab: "updates"),
        Mail(from: "Example Stream <billing@stream.example.test>", subject: "Your subscription renews Oct 5", preview: "No action needed.", tab: "updates"),
        Mail(from: "Parcel Example <track@parcel.example.test>", subject: "Package delivered", preview: "Left at the front door.", tab: "updates"),
        Mail(from: "Example Salon <noreply@salon.example.test>", subject: "Your appointment is confirmed", preview: "See you Saturday at 11.", tab: "updates")
    ]

    /// Lists, newsletters and promotions.
    private static let lists = [
        Mail(from: "Shop Example <deals@shop.example.test>", subject: "50% off everything", preview: "Today only.", tab: "promotions", bulk: true),
        Mail(from: "Design Weekly <news@designweekly.example.test>", subject: "This week in design", preview: "Five studios worth a look.", tab: "promotions", bulk: true),
        Mail(from: "Neighbors <notify@neighbors.example.test>", subject: "New comments in Neighbors", preview: "3 new comments on a post you follow.", tab: "social", bulk: true),
        Mail(from: "Example News <digest@news.example.test>", subject: "Top stories for you", preview: "Today’s headlines.", tab: "updates", bulk: true),
        Mail(from: "Outdoor Example <sale@outdoors.example.test>", subject: "Flash sale ends tonight", preview: "Tents and packs up to 40% off.", tab: "promotions", bulk: true),
        Mail(from: "Example Careers <jobs@careers.example.test>", subject: "New jobs for you", preview: "12 new roles match your search.", tab: "updates", bulk: true),
        Mail(from: "Hobby Forum <forum@hobby.example.test>", subject: "Your weekly forum digest", preview: "Popular threads this week.", tab: "forums", bulk: true),
        Mail(from: "Pantry Example <hello@pantry.example.test>", subject: "Free shipping this weekend", preview: "No minimum.", tab: "promotions", bulk: true),
        Mail(from: "Example Software <events@saas.example.test>", subject: "Webinar: planning your year", preview: "Save your seat.", tab: "promotions", bulk: true),
        Mail(from: "Example Social <notify@social.example.test>", subject: "You have 3 new followers", preview: "See who’s following you.", tab: "social", bulk: true),
        Mail(from: "Market Example <deals@market.example.test>", subject: "Deals picked for you", preview: "Based on what you viewed.", tab: "promotions", bulk: true),
        Mail(from: "Kitchen Example <recipes@kitchen.example.test>", subject: "Recipe of the week", preview: "One-pan lemon chicken.", tab: "promotions", bulk: true),
        Mail(from: "Hobby Forum <events@hobby.example.test>", subject: "Community meetup Thursday", preview: "RSVP by Wednesday.", tab: "forums", bulk: true),
        Mail(from: "Shoes Example <sale@shoes.example.test>", subject: "Last chance: 30% off", preview: "Ends at midnight.", tab: "promotions", bulk: true)
    ]
}
