import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct CalendarDataTests {
    @Test func incompleteTeachingCanBeSavedWithoutInventingAccountOrTimeZone() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let source = LearnedCalendarSource(name: "Work schedule", meaning: "My meetings", application: "Outlook")
        let store = CalendarStore(directory: fixture.directory)
        try store.saveSource(source)
        #expect(store.sources == [source])
        #expect(CalendarStore(directory: fixture.directory).sources == [source])
        #expect(throws: CalendarDataError.self) { try CalendarReadRequest(source: source, day: Date()).validate() }
    }

    @Test func collectionVerifiesSourceDateTimezoneAndVisibleProvenance() throws {
        let fixture = Fixture()
        let request = fixture.request()
        let input = fixture.submission(request)
        let result = try CalendarSubmission.parse(input, request: request)
        #expect(result.id == request.id)
        #expect(result.sourceID == request.source.id)
        #expect(result.day == request.dayInterval.start)
        #expect(result.accountEvidence == "Account menu: person@example.com")
        for (key, replacement) in [("sourceID", UUID().uuidString), ("day", "2026-09-29"),
                                   ("timeZoneID", "UTC"), ("accountEvidence", " "),
                                   ("calendarEvidence", ""), ("dateEvidence", "")] {
            var changed = input
            changed[key] = replacement
            #expect(throws: CalendarDataError.self) { try CalendarSubmission.parse(changed, request: request) }
        }
    }

    @Test func timestampParserRequiresExplicitOffsetAndRejectsNormalizedInvalidDates() throws {
        let valid = try CalendarSubmission.timestamp("2026-09-28T09:30:00-04:00")
        #expect(valid == (try CalendarSubmission.timestamp("2026-09-28T13:30:00Z")))
        #expect(try CalendarSubmission.timestamp("2026-09-28T13:30:00.125Z").timeIntervalSince(valid) == 0.125)
        for value in ["2026-09-28T09:30:00", "2026-02-30T09:30:00Z", "2026-09-28T24:00:00Z",
                      "2026-09-28T09:30:60Z", "2026-09-28T09:30:00+25:00", "2026-09-28 09:30:00Z"] {
            #expect(throws: CalendarDataError.self) { try CalendarSubmission.timestamp(value) }
        }
    }

    @Test func duplicateRowsAreDeduplicatedWithStableIdentityButConflictsFail() throws {
        let fixture = Fixture()
        let request = fixture.request()
        var input = fixture.submission(request)
        let row = fixture.row()
        input["events"] = [row, row]
        let first = try CalendarSubmission.parse(input, request: request)
        let second = try CalendarSubmission.parse(input, request: fixture.request())
        #expect(first.events.count == 1)
        #expect(first.events.first?.id == second.events.first?.id)
        #expect(first.events.first?.id.hasPrefix("derived-") == true)
        var explicit = row
        explicit["id"] = "source-event-123"
        var changed = explicit
        changed["end"] = "2026-09-28T11:00:00-04:00"
        input["events"] = [explicit, changed]
        #expect(throws: CalendarDataError.self) { try CalendarSubmission.parse(input, request: request) }
    }

    @Test func parserRejectsWrongDayReversedTimesInvalidEnumsAndNonBooleanFlags() throws {
        let fixture = Fixture()
        let request = fixture.request()
        for (key, value) in [("start", "2026-09-29T09:00:00-04:00" as Any),
                             ("end", "2026-09-28T08:00:00-04:00" as Any),
                             ("response", "yes" as Any), ("availability", "probablyFree" as Any),
                             ("allDay", 1 as Any), ("evidence", "" as Any)] {
            var input = fixture.submission(request)
            var row = fixture.row()
            row[key] = value
            input["events"] = [row]
            #expect(throws: CalendarDataError.self) { try CalendarSubmission.parse(input, request: request) }
        }
        var partial = fixture.submission(request)
        partial["coverage"] = "partial"
        #expect(throws: CalendarDataError.self) { try CalendarSubmission.parse(partial, request: request) }
        partial["coverageNotes"] = ["The evening events could not be opened."]
        #expect(try CalendarSubmission.parse(partial, request: request).coverage == .partial)
    }

    @Test func briefingMergesBackToBackBlocksFindsAcceptedOverlapsAndClipsOpenings() throws {
        let fixture = Fixture()
        let snapshot = fixture.snapshot(events: [
            fixture.event("Before work", "08:00", "09:30"),
            fixture.event("Standup", "09:30", "10:00"),
            fixture.event("Review", "10:00", "12:30"),
            fixture.event("One", "13:30", "14:30"),
            fixture.event("Two", "14:00", "15:00"),
            fixture.event("Evening", "17:00", "18:00")
        ])
        let facts = CalendarBriefing.analyze(snapshot)
        #expect(facts.busyBlocks == [fixture.interval("09:00", "12:30"), fixture.interval("13:30", "15:00")])
        #expect(facts.freeWindows == [fixture.interval("12:30", "13:30"), fixture.interval("15:00", "17:00")])
        #expect(facts.acceptedOverlaps.count == 1)
        #expect(facts.acceptedOverlaps.first?.interval == fixture.interval("14:00", "14:30"))
        let text = CalendarBriefing.render(snapshot)
        #expect(text.contains("12:30 PM–1:30 PM"))
        #expect(text.contains("3:00 PM–5:00 PM"))
        #expect(!text.contains("lunch") && !text.contains("priority") && !text.contains("tomorrow"))
    }

    @Test func partialCoverageAndUnknownAvailabilityNeverClaimOpenTime() throws {
        let fixture = Fixture()
        var snapshot = fixture.snapshot(events: [])
        snapshot.coverage = .partial
        snapshot.coverageNotes = ["Could not expand all-day items."]
        #expect(CalendarBriefing.analyze(snapshot).freeWindows.isEmpty)
        #expect(!CalendarBriefing.analyze(snapshot).hasReliableOpenings)
        #expect(CalendarBriefing.render(snapshot).contains("does not establish an empty schedule"))
        var unknown = fixture.event("Details unavailable", "11:00", "12:00")
        unknown.availability = .unknown
        snapshot = fixture.snapshot(events: [unknown])
        #expect(CalendarBriefing.analyze(snapshot).freeWindows.isEmpty)
        #expect(CalendarBriefing.render(snapshot).contains("unknown availability"))
    }

    @Test func declinedFreeAndCancelledEventsDoNotBlockOrInvalidateOpenings() throws {
        let fixture = Fixture()
        var declined = fixture.event("Declined", "09:00", "17:00")
        declined.response = .declined
        declined.availability = .unknown
        var free = fixture.event("Reminder", "09:00", "17:00")
        free.availability = .free
        var cancelled = fixture.event("Cancelled", "09:00", "17:00")
        cancelled.isCancelled = true
        cancelled.availability = .unknown
        let snapshot = fixture.snapshot(events: [declined, free, cancelled])
        let facts = CalendarBriefing.analyze(snapshot)
        #expect(facts.busyBlocks.isEmpty && facts.acceptedOverlaps.isEmpty)
        #expect(facts.hasReliableOpenings)
        #expect(facts.freeWindows == [fixture.interval("09:00", "17:00")])
    }

    @Test func acceptedMeetingsMarkedFreeStillHaveFactualOverlaps() throws {
        let fixture = Fixture()
        var first = fixture.event("One", "13:00", "14:00")
        var second = fixture.event("Two", "13:30", "14:30")
        first.availability = .free
        second.availability = .free
        let facts = CalendarBriefing.analyze(fixture.snapshot(events: [first, second]))
        #expect(facts.busyBlocks.isEmpty)
        #expect(facts.acceptedOverlaps.count == 1)
        #expect(facts.acceptedOverlaps.first?.interval == fixture.interval("13:30", "14:00"))
    }

    @Test func allDayBusyEventsBlockTheWindowAndMidnightEndIsExclusive() throws {
        let fixture = Fixture()
        var allDay = fixture.event("Away", "00:00", "23:00")
        allDay.end = fixture.request().dayInterval.end
        allDay.allDay = true
        let snapshot = fixture.snapshot(events: [allDay])
        try snapshot.validate()
        #expect(CalendarBriefing.analyze(snapshot).busyBlocks == [fixture.interval("09:00", "17:00")])
        #expect(CalendarBriefing.analyze(snapshot).freeWindows.isEmpty)
        var previous = allDay
        previous.start = allDay.start.addingTimeInterval(-86400)
        previous.end = allDay.start
        #expect(throws: CalendarDataError.self) { try fixture.snapshot(events: [previous]).validate() }
        allDay.end = fixture.time("23:00")
        #expect(throws: CalendarDataError.self) { try fixture.snapshot(events: [allDay]).validate() }
    }

    @Test func daylightSavingDaysUseCalendarBoundariesAndWallClockWorkHours() throws {
        let fixture = Fixture()
        let spring = try CalendarSubmission.timestamp("2026-03-08T12:00:00-04:00")
        let fall = try CalendarSubmission.timestamp("2026-11-01T12:00:00-05:00")
        let springRequest = CalendarReadRequest(source: fixture.source, day: spring)
        let fallRequest = CalendarReadRequest(source: fixture.source, day: fall)
        try springRequest.validate()
        try fallRequest.validate()
        #expect(springRequest.dayInterval.duration == 23 * 3600)
        #expect(fallRequest.dayInterval.duration == 25 * 3600)
        #expect(springRequest.windowInterval.start == (try CalendarSubmission.timestamp("2026-03-08T09:00:00-04:00")))
        #expect(fallRequest.windowInterval.start == (try CalendarSubmission.timestamp("2026-11-01T09:00:00-05:00")))
        #expect(springRequest.windowInterval.duration == 8 * 3600)
        let nonexistent = CalendarReadRequest(source: fixture.source, day: spring, startHour: 2, endHour: 3)
        #expect(throws: CalendarDataError.self) { try nonexistent.validate() }
        let allDay = CalendarEventRecord(id: "dst", title: "All-day", start: springRequest.dayInterval.start,
                                        end: springRequest.dayInterval.end, allDay: true, response: .accepted,
                                        availability: .busy, evidence: "All-day, busy")
        let snapshot = CalendarSnapshot(sourceID: fixture.source.id, day: spring, timeZoneID: fixture.source.timeZoneID,
                                        events: [allDay], coverage: .complete, accountEvidence: "Account", calendarEvidence: "Work", dateEvidence: "Mar 8")
        try snapshot.validate()
        #expect(CalendarBriefing.analyze(snapshot).freeWindows.isEmpty)
    }

    @Test func savingAgainReplacesTheDayAndRetainsOtherDaysWithoutDuplicateEvents() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = CalendarStore(directory: fixture.directory)
        try store.saveSource(fixture.source)
        let request = fixture.request()
        let first = try CalendarSubmission.parse(fixture.submission(request), request: request)
        try store.saveSnapshot(first)
        var next = fixture.snapshot(events: [fixture.event("New meeting", "10:00", "11:00")])
        next.collectedAt = first.collectedAt.addingTimeInterval(60)
        try store.saveSnapshot(next)
        #expect(store.snapshots == [next])
        var otherDay = next
        otherDay.id = UUID()
        otherDay.day = next.day.addingTimeInterval(86400)
        otherDay.events = []
        otherDay.collectedAt = next.collectedAt.addingTimeInterval(60)
        try store.saveSnapshot(otherDay)
        #expect(store.snapshots.count == 2)
        #expect(store.latest(for: fixture.source.id) == otherDay)
        let reopened = CalendarStore(directory: fixture.directory)
        #expect(reopened.sources == store.sources && reopened.snapshots == store.snapshots)
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func corruptAndNewerWorkspacesRemainUntouchedAndBlockMutation() throws {
        for bytes in [Data("not json".utf8), Data(#"{"version":99,"sources":[],"snapshots":[]}"#.utf8)] {
            let fixture = Fixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
            try bytes.write(to: fixture.file)
            let store = CalendarStore(directory: fixture.directory)
            #expect(store.error != nil)
            #expect(throws: CalendarDataError.self) { try store.saveSource(fixture.source) }
            #expect(try Data(contentsOf: fixture.file) == bytes)
        }
    }

    @Test func malformedStoredSnapshotsCannotBypassSubmissionValidation() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = CalendarStore(directory: fixture.directory)
        try store.saveSource(fixture.source)
        try store.saveSnapshot(fixture.snapshot(events: [fixture.event("Meeting", "10:00", "11:00")]))
        let run = try #require(store.runStore.runs.first)
        let archive = try #require(store.runStore.directory(for: run.id)).appendingPathComponent("run.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        var rows = try #require(object["entries"] as? [[String: Any]])
        var snapshot = try #require(rows[0]["calendarSnapshot"] as? [String: Any])
        snapshot["accountEvidence"] = ""
        rows[0]["calendarSnapshot"] = snapshot
        object["entries"] = rows
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        try corrupted.write(to: archive)
        let reopened = CalendarStore(directory: fixture.directory)
        #expect(reopened.error != nil)
        #expect(throws: CalendarDataError.self) { try reopened.saveSnapshot(fixture.snapshot(events: [])) }
        #expect(try Data(contentsOf: archive) == corrupted)
    }

    @Test func sourceIdentityEditsHideOldResultsAndCannotRelabelAnInFlightCollection() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = CalendarStore(directory: fixture.directory)
        try store.saveSource(fixture.source)
        let request = fixture.request()
        let original = try CalendarSubmission.parse(fixture.submission(request), request: request)
        try store.saveSnapshot(original)
        var edited = fixture.source
        edited.name = "A more useful label"
        edited.navigationHints = "Switch to day view"
        try store.saveSource(edited)
        #expect(store.latest(for: edited.id) == original)
        edited.account = "different@example.com"
        try store.saveSource(edited)
        #expect(store.latest(for: edited.id) == nil)
        #expect(store.snapshots == [original])
        let reopened = CalendarStore(directory: fixture.directory)
        #expect(reopened.latest(for: edited.id) == nil)
        #expect(reopened.snapshots == [original])
        // A read that started before the edit must retain the account it actually read.
        let late = try CalendarSubmission.parse(fixture.submission(request), request: request)
        try reopened.saveSnapshot(late)
        #expect(reopened.snapshots.first?.source?.account == fixture.source.account)
        #expect(reopened.latest(for: edited.id) == nil)
    }

    @Test func failedWriteDoesNotPublishOrLosePreviousSnapshot() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = CalendarStore(directory: fixture.directory)
        try store.saveSource(fixture.source)
        let first = fixture.snapshot(events: [])
        try store.saveSnapshot(first)
        let archive = try #require(store.runStore.archiveDirectory)
        let backup = fixture.directory.appendingPathComponent("runs-backup")
        try FileManager.default.moveItem(at: archive, to: backup)
        try Data("Blocked".utf8).write(to: archive)
        #expect(throws: (any Error).self) { try store.saveSnapshot(fixture.snapshot(events: [fixture.event("New", "10:00", "11:00")])) }
        #expect(store.snapshots == [first])
        #expect(store.error != nil)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: backup, to: archive)
        #expect(CalendarStore(directory: fixture.directory).snapshots == [first])
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarDataTests-\(UUID().uuidString)")
        let source = LearnedCalendarSource(name: "Work", meaning: "My work meeting schedule", application: "Outlook", bundleID: "com.microsoft.Outlook",
                                          account: "person@example.com", calendarName: "Work", timeZoneID: "America/New_York",
                                          navigationHints: "Open calendar; use date picker", completionChecks: "Check account, selected calendar, date, and all-day section")
        var file: URL { directory.appendingPathComponent("workspace.json") }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func time(_ value: String) -> Date { try! CalendarSubmission.timestamp("2026-09-28T\(value):00-04:00") }
        func interval(_ start: String, _ end: String) -> DateInterval { DateInterval(start: time(start), end: time(end)) }
        func request() -> CalendarReadRequest { CalendarReadRequest(source: source, day: time("12:00")) }
        func row() -> [String: Any] {
            ["title": "Review", "start": "2026-09-28T09:00:00-04:00", "end": "2026-09-28T10:00:00-04:00",
             "allDay": false, "response": "accepted", "availability": "busy", "isCancelled": false,
             "evidence": "Review 9–10 AM, accepted, show as busy"]
        }
        func submission(_ request: CalendarReadRequest) -> [String: Any] {
            ["sourceID": source.id.uuidString, "day": request.dateLabel, "timeZoneID": source.timeZoneID,
             "coverage": "complete", "coverageNotes": [String](),
             "accountEvidence": "Account menu: person@example.com", "calendarEvidence": "Selected calendar: Work",
             "dateEvidence": "Header: September 28, 2026; Eastern time", "events": [row()]]
        }
        func event(_ name: String, _ start: String, _ end: String) -> CalendarEventRecord {
            CalendarEventRecord(id: name, title: name, start: time(start), end: time(end), response: .accepted,
                                availability: .busy, evidence: "\(name), \(start)–\(end), accepted, busy")
        }
        func snapshot(events: [CalendarEventRecord]) -> CalendarSnapshot {
            CalendarSnapshot(sourceID: source.id, day: request().dayInterval.start, timeZoneID: source.timeZoneID,
                             events: events, coverage: .complete, accountEvidence: "Account menu: person@example.com",
                             calendarEvidence: "Selected calendar: Work", dateEvidence: "September 28, 2026, Eastern time", source: source)
        }
    }
}
