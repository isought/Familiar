import Foundation
import Testing
@testable import Familiar

/// The attention ledger is one owner-only file of JSON lines that is only ever appended to: a torn or unknown
/// line is skipped rather than fatal, every line carries its schema, local time, day and zone, and the keys a
/// later filter learns from are frozen.
@Suite
struct AttentionLogFileTests {
    @Test func appendWritesOneLinePerEventInAnOwnerOnlyFolder() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let events = [event(.started), event(.opened(.init(trigger: .launcher, route: "folders", desk: 6))), event(.label(label()))]
        try fixture.log.append(events)

        #expect(try mode(fixture.folder) == 0o700 && mode(fixture.log.url) == 0o600)
        let text = try String(contentsOf: fixture.log.url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 3)
        for line in lines { #expect(try object(Data(line.utf8))["schema"] as? Int == 1) }
        #expect(AttentionLogFile.read(fixture.log.url).events == events)

        // A folder or file someone loosened is owner-only again after the next append.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.log.url.path)
        try fixture.log.append([event(.started)])
        #expect(try mode(fixture.folder) == 0o700 && mode(fixture.log.url) == 0o600)
    }

    @Test func appendNeverRewritesEarlierBytes() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = [event(.started), event(.label(label()))], next = event(.miss(.init(key: "k", retract: false, item: item())))
        try fixture.log.append(first)
        let before = try Data(contentsOf: fixture.log.url)
        let file = try FileManager.default.attributesOfItem(atPath: fixture.log.url.path)[.systemFileNumber] as? NSNumber

        try fixture.log.append([next])
        try fixture.log.append([])
        let after = try Data(contentsOf: fixture.log.url)
        #expect(after.prefix(before.count) == before)
        #expect(try after.count == before.count + next.line().count + 1)   // no seal before a line that ended cleanly
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.log.url.path)[.systemFileNumber] as? NSNumber == file)
        #expect(AttentionLogFile.read(fixture.log.url).events == first + [next])
    }

    @Test func aTornLastLineIsSkippedAndSealedBeforeTheNextAppend() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = event(.started)
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        try (first.line() + Data("\n{\"schema\":1,\"ty".utf8)).write(to: fixture.log.url)

        let torn = AttentionLogFile.read(fixture.log.url)
        #expect(torn.events == [first] && torn.skipped == 1)

        let next = event(.opened(.init(trigger: .menu, route: "card", desk: 2)))
        try fixture.log.append([next])
        let sealed = AttentionLogFile.read(fixture.log.url)
        #expect(sealed.events == [first, next] && sealed.skipped == 1)
        #expect(try String(contentsOf: fixture.log.url, encoding: .utf8).hasSuffix("{\"schema\":1,\"ty\n" + String(decoding: next.line(), as: UTF8.self) + "\n"))
    }

    @Test func unknownTypesAndNewerSchemasAreSkippedNotFatal() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let known = event(.restViewed(.init(restDay: "2026-09-29", count: 36, reachedEnd: true, seconds: 41.5)))
        var future = try object(known.line()); future["type"] = "future"
        var newer = try object(known.line()); newer["schema"] = 2
        var elsewhere = try object(known.line()); elsewhere["tz"] = "Nowhere/Atlantis"
        var partial = try object(known.line()); partial["count"] = nil
        let lines = try [known.line()] + [future, newer, elsewhere, partial].map { try JSONSerialization.data(withJSONObject: $0) }
            + [Data("[1,2]".utf8), Data("not json".utf8), Data("   ".utf8)]
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        try (Data(lines.joined(separator: Data("\n".utf8))) + Data("\n\n".utf8)).write(to: fixture.log.url)

        let read = AttentionLogFile.read(fixture.log.url)
        #expect(read.events == [known] && read.skipped == 7)   // the empty line between the last two newlines is not a line
        let next = event(.started)
        try fixture.log.append([next])
        #expect(AttentionLogFile.read(fixture.log.url).events == [known, next])
        #expect(AttentionLogFile.read(fixture.folder.appendingPathComponent("missing.jsonl")) == ([], 0))
    }

    @Test func theFeatureSchemaIsFrozen() throws {
        let envelope: Set = ["schema", "id", "type", "at", "day", "tz", "app"]
        let payloads: [AttentionEventType: Set<String>] = [
            .started: [], .sorted: ["runIDs", "backfilled", "sources", "items", "seen", "screenRead"],
            .label: ["key", "value", "weight", "prior", "text", "via", "item", "card"],
            .implicit: ["key", "signal", "retracts", "optionIndex", "optionMode", "item", "card"],
            .miss: ["key", "retract", "item"], .opened: ["trigger", "route", "desk"],
            .restViewed: ["restDay", "count", "reachedEnd", "seconds"], .engaged: ["key", "what", "card"],
        ]
        let itemKeys: Set = ["key", "sourceID", "sourceName", "kind", "script", "runID", "itemID", "readAt", "subject", "from", "fromName",
            "address", "domain", "tab", "bulk", "important", "starred", "unread", "received", "receivedHour", "receivedWeekday", "ageHours",
            "preview", "url", "shown"]
        let cardKeys: Set = ["cardID", "disposition", "displayDisposition", "optionCount", "optionModes", "cardAgeHours", "userEdited",
            "hasPersonalContext", "createdByRun"]
        let sourceKeys: Set = ["sourceID", "sourceName", "script", "runID", "collectedAt", "since", "arrived", "returned", "truncated"]
        let seenKeys: Set = ["key", "shown"]
        let screenReadKeys: Set = ["sourceID", "sourceName"]

        let events = everyEvent()
        #expect(Set(events.map(\.type)) == Set(AttentionEventType.allCases) && Set(payloads.keys) == Set(AttentionEventType.allCases))
        for event in events {
            let line = try event.line()
            #expect(!line.contains(UInt8(ascii: "\n")))   // a newline in a preview or explanation stays escaped
            let json = try object(line)
            // The payload shares the envelope's object, so a payload key named like an envelope key would silently
            // replace it (a rest day written as `day`, say). Its keys are checked on their own before they share.
            let own = try payloadKeys(event.payload)
            #expect(own == payloads[event.type]! && own.isDisjoint(with: envelope), "\(event.type)")
            #expect(Set(json.keys) == envelope.union(own), "\(event.type)")
            #expect(json["type"] as? String == event.type.rawValue)
            if let item = json["item"] as? [String: Any] { #expect(Set(item.keys) == itemKeys) }
            if let card = json["card"] as? [String: Any] { #expect(Set(card.keys) == cardKeys) }
            for item in json["items"] as? [[String: Any]] ?? [] { #expect(Set(item.keys) == itemKeys) }
            for source in json["sources"] as? [[String: Any]] ?? [] { #expect(Set(source.keys) == sourceKeys) }
            for again in json["seen"] as? [[String: Any]] ?? [] { #expect(Set(again.keys) == seenKeys) }
            for screen in json["screenRead"] as? [[String: Any]] ?? [] { #expect(Set(screen.keys) == screenReadKeys) }
        }
        // A line from before messages read again were listed by key, or before screen reads were named, has no `seen`
        // or `screenRead`, and reads back without them.
        var older = try object(event(.sorted(sorted(items: [item()]))).line())
        older["seen"] = nil
        older["screenRead"] = nil
        let read = try AttentionEvent(line: JSONSerialization.data(withJSONObject: older))
        guard case .sorted(let sorted) = read.payload else {
            Issue.record("An older line did not read back as `sorted`.")
            return
        }
        #expect(sorted.seen == nil && sorted.screenRead == nil && sorted.items == [item()])

        #expect(AttentionEventType.allCases.map(\.rawValue) == ["started", "sorted", "label", "implicit", "miss", "opened", "rest_viewed", "engaged"])
        #expect(AttentionLabelValue.allCases.map(\.rawValue) == ["yes", "no", "strong_yes", "strong_no", "explain", "clear"])
        #expect(AttentionPrior.allCases.map(\.rawValue) == ["yes", "no", "strong_yes", "strong_no", "guess_yes", "guess_no", "none"])
        #expect(AttentionSignal.allCases.map(\.rawValue)
            == ["option_tapped", "context_requested", "mine", "ignored", "handled", "adjusted", "retract"])
        #expect(AttentionOpenTrigger.allCases.map(\.rawValue) == ["launcher", "menu", "task_panel", "chat", "people", "run"])
        #expect(AttentionVia.allCases.map(\.rawValue) == ["card", "shown", "rest"])
        #expect(AttentionEngagement.allCases.map(\.rawValue) == ["card_opened"])
        let given = try object(event(.label(label())).line())
        #expect(given["value"] as? String == "strong_yes" && given["prior"] as? String == "guess_no" && given["via"] as? String == "rest")
        #expect((given["card"] as? [String: Any])?["optionModes"] as? [String] == ["prepare", "desktop"])
    }

    @Test func appendThrowsOnlyPOSIXErrors() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // A value JSON cannot hold is EINVAL, and nothing of the batch is written.
        var unwritable = item()
        unwritable.ageHours = .nan
        #expect(posixCode { try fixture.log.append([event(.started), event(.miss(.init(key: "k", retract: false, item: unwritable)))]) } == EINVAL)
        #expect(!FileManager.default.fileExists(atPath: fixture.log.url.path))

        // Foundation's folder errors come out as the POSIX error under them, not as Cocoa's 516 or 513.
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: fixture.folder)
        #expect(posixCode { try fixture.log.append([event(.started)]) } == EEXIST)
        try FileManager.default.removeItem(at: fixture.folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path) }
        #expect(posixCode { try fixture.log.append([event(.started)]) } == EACCES)
    }

    /// The privacy notice's table of what stays on the Mac lists the ledger's folder and what it holds, and the notice
    /// says who can read it, that it never leaves the Mac, when it is made and when it stops, and how to erase it.
    @Test func thePrivacyNoticeListsTheLedger() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notice = try String(contentsOf: root.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
        let row = try #require(notice.split(separator: "\n").first { $0.hasPrefix("|") && $0.hasSuffix("| `attention/` |") })
        for held in ["subject", "sender", "address", "preview", "link", "names of mail jobs that read from the screen", "thumbs",
                     "explanations", "open the pack"] {
            #expect(row.contains(held), "The row doesn't say it holds \(held).")
        }
        let paragraph = try #require(notice.components(separatedBy: "\n\n").first { $0.hasPrefix("The attention test") })
        for said in ["only once a mail job that reads through a script has run", "only ever adds to",
                     "stops adding what you do once a week passes with no such read", "never leaves your Mac",
                     "delete the `attention` folder", "starts again"] {
            #expect(paragraph.contains(said), "The notice doesn't say “\(said)”.")
        }
        #expect(notice.contains("the attention test and the activity log can be read only by your macOS user account"))
    }

    @Test func timesCarryTheLocalOffsetDayAndZone() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let at = try #require(AttentionTime.date("2026-09-30T12:14:03.120Z"))
        let morning = try object(AttentionEvent(.started, at: at, timeZone: newYork).line())
        #expect(morning["at"] as? String == "2026-09-30T08:14:03.120-04:00")
        #expect(morning["day"] as? String == "2026-09-30" && morning["tz"] as? String == "America/New_York")

        // Late evening is still that local day, and winter has its own offset.
        let evening = AttentionEvent(.started, at: try #require(AttentionTime.date("2026-10-01T02:30:00Z")), timeZone: newYork)
        #expect(try object(evening.line())["at"] as? String == "2026-09-30T22:30:00.000-04:00" && evening.day == "2026-09-30")
        let winter = AttentionEvent(.started, at: try #require(AttentionTime.date("2026-12-01T12:00:00.000+00:00")), timeZone: newYork)
        #expect(try object(winter.line())["at"] as? String == "2026-12-01T07:00:00.000-05:00")

        // Times inside the payload use the event's zone too, and all of them read back as the same instant.
        let read = event(.sorted(sorted(items: [item()])), at: at, zone: newYork)
        let source = try #require((object(read.line())["sources"] as? [[String: Any]])?.first)
        #expect((source["collectedAt"] as? String)?.hasSuffix("-04:00") == true)
        #expect(try AttentionEvent(line: read.line()) == read)
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(AttentionTime.date(AttentionTime.string(at, in: tokyo)) == at && AttentionTime.day(of: at, in: tokyo) == "2026-09-30")
    }

    @Test func theLedgersOwnTimesReadTheSameWithoutAFormatter() {
        let milliseconds = ISO8601DateFormatter(), whole = ISO8601DateFormatter()
        milliseconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        whole.formatOptions = [.withInternetDateTime]
        /// How times were read before: by the formatters alone.
        func formatted(_ text: String) -> Date? { milliseconds.date(from: text).map(AttentionTime.toTheMillisecond) ?? whole.date(from: text) }

        // From 1906 to 2112, in zones with half- and quarter-hour offsets, the date line's both sides and UTC: as the
        // ledger writes them, and in whole seconds as the mail script gives them.
        let zones = ["UTC", "America/New_York", "America/Los_Angeles", "America/St_Johns", "Asia/Kolkata", "Asia/Kathmandu",
                     "Australia/Lord_Howe", "Pacific/Chatham", "Pacific/Kiritimati", "Pacific/Pago_Pago"]
        let times = zones.compactMap(TimeZone.init(identifier:)).flatMap { zone in
            let seconds = ISO8601DateFormatter()
            seconds.formatOptions = [.withInternetDateTime]
            seconds.timeZone = zone
            return (0..<500).flatMap { step in
                let date = Date(timeIntervalSince1970: -2_000_000_000 + Double(step) * 13_000_003.217)
                return [AttentionTime.string(date, in: zone), seconds.string(from: date)]
            }
        }
        let mismatches = times.filter { AttentionTime.date($0) != formatted($0) }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
        // Reading them by hand is what keeps the launch read short: well under a third of the formatters' time.
        func fastest(_ read: (String) -> Date?) -> TimeInterval {
            (0..<3).map { _ in
                let started = Date()
                _ = times.map(read)
                return Date().timeIntervalSince(started)
            }.min() ?? 0
        }
        #expect(fastest(AttentionTime.date) * 3 < fastest(formatted))
        #expect(AttentionTime.date("2026-09-30T08:14:03.120-04:00") == Date(timeIntervalSince1970: 1_790_770_443.12))
        #expect(AttentionTime.date("2026-09-30T12:10:00+00:00") == AttentionTime.date("2026-09-30T08:10:00.000-04:00"))

        // Forms the ledger never writes, and times that are not times, read as the formatters read them.
        for text in ["2026-09-30T08:14:03.1Z", "2026-09-30T08:14:03.12345+02:00", "2026-09-30T08:14:03+0530", "2026-09-30 08:14:03Z",
                     "2026-02-29T08:00:00Z", "2024-02-29T08:00:00Z", "2026-09-31T08:00:00Z", "2026-09-30T24:00:00Z", "2026-09-30t08:14:03z",
                     "1899-12-31T23:59:59Z", "2026-09-30T08:14:03.120+19:00", "2026-09-30T08:14:03", "garbage", ""] {
            #expect(AttentionTime.date(text) == formatted(text), "\(text)")
        }
    }

    @Test func aTwoHundredItemSortedLineRoundTrips() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // Every field at its longest: a 280-character preview, a long subject and a Gmail link built from a Message-ID.
        let items = (0..<200).map { index in
            item(index: index, readAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7 + Double(index) * 61.7))
        }
        let sorted = event(.sorted(sorted(items: items)), at: Date(timeIntervalSinceReferenceDate: 812_345_999.987_654_3))
        try fixture.log.append([sorted])

        // About 1.25 KB an item at its longest, most of it the preview and the link.
        let size = try #require(FileManager.default.attributesOfItem(atPath: fixture.log.url.path)[.size] as? NSNumber).intValue
        #expect(size < 300_000)
        #expect(AttentionLogFile.read(fixture.log.url).events == [sorted])   // times kept to the millisecond read back equal
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-log-\(UUID())")
        var folder: URL { root.appendingPathComponent("attention") }
        var log: AttentionLogFile { AttentionLogFile(url: folder.appendingPathComponent("signals.jsonl")) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private let sourceID = UUID(), runID = UUID()

    private func event(_ payload: AttentionEvent.Payload, at: Date = Date(), zone: TimeZone = TimeZone(identifier: "America/New_York")!) -> AttentionEvent {
        AttentionEvent(payload, at: at, timeZone: zone, app: "0.5.4")
    }

    /// One event of every type, every field filled.
    private func everyEvent() -> [AttentionEvent] {
        [event(.started), event(.sorted(sorted(items: [item(), item(index: 1)], seen: [.init(key: "k2", shown: true)],
                                               screenRead: [.init(sourceID: UUID(), sourceName: "Gmail inbox – today’s unread")]))),
         event(.label(label())),
         event(.implicit(.init(key: "k", signal: .retract, retracts: .optionTapped, optionIndex: 1, optionMode: .prepare, item: item(), card: card()))),
         event(.miss(.init(key: "k", retract: true, item: item()))), event(.opened(.init(trigger: .taskPanel, route: "card", desk: 4))),
         event(.restViewed(.init(restDay: "2026-09-29", count: 36, reachedEnd: true, seconds: 41.5))),
         event(.engaged(.init(key: "k", what: .cardOpened, card: card())))]
    }

    private func sorted(items: [AttentionItem], seen: [AttentionEvent.Sorted.Seen]? = nil,
                        screenRead: [AttentionEvent.Sorted.ScreenRead]? = nil) -> AttentionEvent.Sorted {
        AttentionEvent.Sorted(runIDs: [runID], backfilled: true, sources: [.init(sourceID: sourceID, sourceName: "Example Gmail",
            script: "imap-mail__today", runID: runID, collectedAt: Date(timeIntervalSinceReferenceDate: 812_345_600.000_4),
            since: Date(timeIntervalSinceReferenceDate: 812_259_200.5), arrived: 240, returned: 200, truncated: true)], items: items, seen: seen,
            screenRead: screenRead)
    }

    private func label() -> AttentionEvent.Label {
        .init(key: "k", value: .strongYes, weight: 2, prior: .guessNo, text: "Rent is due.\nThis matters.", via: .rest, item: item(), card: card())
    }

    private func item(index: Int = 0, readAt: Date = Date(timeIntervalSinceReferenceDate: 812_345_600.25)) -> AttentionItem {
        let messageID = "CAB\(index)x7Hq2+kd9=Lm4_Pq8Zr-Yv3@mail.example.test"
        let preview = String(repeating: "Your lease renewal is attached; please sign and return it by Friday so the rent stays the same. ", count: 3)
        return AttentionItem(key: CardObservation.key(sourceID: sourceID, itemKey: messageID), sourceID: sourceID, sourceName: "Example Gmail",
            kind: "mail", script: "imap-mail__today", runID: runID, itemID: ObservedItemIdentity.id(sourceID: sourceID, key: messageID),
            readAt: readAt, subject: "Lease renewal for 14 Example Street, apartment 3: please sign and return by Friday \(index)",
            from: "\"Ruiz, Dana\" <dana.ruiz@rent.example.test>", fromName: "Ruiz, Dana", address: "dana.ruiz@rent.example.test",
            domain: "rent.example.test", tab: "primary", bulk: false, important: true, starred: false, unread: true,
            received: readAt.addingTimeInterval(-3_600 * 5.5), receivedHour: 7, receivedWeekday: 4, ageHours: 5.5,
            preview: String(preview.prefix(AttentionItem.previewLimit)),
            url: "https://mail.google.com/mail/u/me@example.test/#search/" + "rfc822msgid:\(messageID)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
            shown: index % 7 == 0)
    }

    private func card() -> AttentionCardContext {
        AttentionCardContext(cardID: UUID(), disposition: .unreviewed, displayDisposition: .unreviewed, optionCount: 2,
            optionModes: [.prepare, .desktop], cardAgeHours: 3.25, userEdited: false, hasPersonalContext: true, createdByRun: runID)
    }

    /// The keys a payload writes by itself, before they share a line with the envelope's.
    private func payloadKeys(_ payload: AttentionEvent.Payload) throws -> Set<String> {
        let value: (any Encodable)?
        switch payload {
        case .started: value = nil
        case .sorted(let sorted): value = sorted
        case .label(let label): value = label
        case .implicit(let signal): value = signal
        case .miss(let miss): value = miss
        case .opened(let opened): value = opened
        case .restViewed(let rest): value = rest
        case .engaged(let engaged): value = engaged
        }
        guard let value else { return [] }
        return try Set(object(JSONEncoder().encode(value)).keys)
    }

    /// The POSIX code `body` threw, or nil when it did not throw; any other kind of error fails the test.
    private func posixCode(_ body: () throws -> Void) -> Int32? {
        do { try body() } catch {
            let error = error as NSError
            #expect(error.domain == NSPOSIXErrorDomain, "\(error)")
            return Int32(error.code)
        }
        return nil
    }

    private func object(_ line: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private func mode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}
