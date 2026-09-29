import Foundation
import Testing
@testable import Familiar

struct SourceResultPresentationTests {
    @Test func completeFindingsComeWithoutRulesOrVerboseEvidence() {
        let fixture = ReadingFixture()
        let view = SourceResultPresentation(entry: fixture.entry)
        #expect(view.notice == nil)
        #expect(view.items.map(\.title) == ["First observed message", "Second observed message"])
        #expect(view.items.map(\.text) == ["Taylor · Today · Review the agenda.", "Morgan · Yesterday · Meeting moved."])
        #expect(!view.dateLabel.contains("SAVED RULES"))
        #expect(!view.items.contains { $0.text.contains("EVIDENCE") || $0.text.contains("LONG NOTE") })
        #expect(view.details.contains { $0.text.contains("LONG NOTE 7") })
        #expect(view.details.contains { $0.text.contains("EVIDENCE") })
        #expect(!view.details.contains { $0.text.contains("SAVED RULES") })
    }

    @Test func partialShowsOneBoundedGapAndRetainsFindingsAndAllDetails() {
        var entry = ReadingFixture().entry
        entry.state = .partial
        entry.readingSnapshot?.coverage = .partial
        entry.readingSnapshot?.coverageNotes.insert("Older pages were not verified. " + String(repeating: "Unverified details. ", count: 100), at: 0)
        let view = SourceResultPresentation(entry: entry)
        #expect(view.items.count == 2)
        #expect(view.notice?.contains("Older pages were not verified") == true)
        #expect((view.notice?.count ?? 0) < 210)
        #expect(view.details.first?.text.contains("LONG NOTE 7") == true)
    }

    @Test func failedAndInterruptedRunsNeverPretendAnEmptySuccessfulRead() {
        for state: SourceRunEntry.State in [.failed, .stopped, .notRun, .interrupted] {
            var entry = ReadingFixture().entry
            entry.state = state
            entry.readingSnapshot = nil
            entry.message = "The account could not be verified."
            let view = SourceResultPresentation(entry: entry)
            #expect(view.state == state)
            #expect(view.items.isEmpty)
            #expect(view.emptyMessage.contains("No new findings were saved"))
            #expect(view.notice == entry.message)
            #expect(view.details.isEmpty)
            if state == .interrupted { #expect(view.stateLabel == "Interrupted") }
        }
    }

    @Test func calendarRetainsTimezoneAndFactsButNeverInventsOpeningsForPartialOrUnknownCoverage() throws {
        let day = ISO8601DateFormatter().date(from: "2026-09-29T13:00:00Z")!
        let source = LearnedCalendarSource(name: "Work", meaning: "Work schedule", application: "Calendar",
            account: "alex@example.test", calendarName: "Work", timeZoneID: "America/New_York")
        let request = CalendarReadRequest(source: source, day: day)
        let first = CalendarEventRecord(id: "one", title: "First meeting", start: day, end: day.addingTimeInterval(3600),
            response: .accepted, availability: .busy, evidence: "Observed first meeting")
        let second = CalendarEventRecord(id: "two", title: "Second meeting", start: day.addingTimeInterval(1800), end: day.addingTimeInterval(5400),
            response: .accepted, availability: .busy, evidence: "Observed second meeting")
        var snapshot = CalendarSnapshot(sourceID: source.id, day: day, timeZoneID: source.timeZoneID,
            events: [first, second], coverage: .complete, accountEvidence: "Observed account",
            calendarEvidence: "Observed Work calendar", dateEvidence: "Observed date", source: source)
        try snapshot.validate()
        func present(_ snapshot: CalendarSnapshot) -> SourceResultPresentation {
            var entry = SourceRunEntry(calendar: request, state: snapshot.coverage == .complete ? .complete : .partial)
            entry.calendarSnapshot = snapshot
            return SourceResultPresentation(entry: entry)
        }
        let complete = present(snapshot)
        #expect(complete.dateLabel.contains("America/New_York"))
        #expect(complete.items.count == 2)
        #expect(complete.calendarFacts.contains { $0.title.contains("overlaps · 1") })
        #expect(complete.calendarFacts.contains { $0.title.contains("blocks · 1") })
        #expect(complete.calendarFacts.last?.text.contains("Openings reflect only") == true)
        snapshot.coverage = .partial
        snapshot.coverageNotes = ["Afternoon was not checked."]
        #expect(present(snapshot).calendarFacts.last?.text.contains("Open time is unverified") == true)
        snapshot.coverage = .complete
        snapshot.events[0].availability = .unknown
        #expect(present(snapshot).calendarFacts.last?.text.contains("Open time is unverified") == true)
    }

    private struct ReadingFixture {
        var entry: SourceRunEntry
        init() {
            let source = LearnedReadingSource(kind: .mail, name: "Work inbox", meaning: "Messages that need attention",
                url: "https://mail.example.test/inbox", account: "alex@example.test",
                scope: String(repeating: "SAVED RULES: unread recent messages only. ", count: 200))
            let request = ReadingReadRequest(source: source)
            let snapshot = ReadingSnapshot(requestID: request.id, sourceID: source.id, source: source, items: [
                ReadingItem(id: "one", title: "First observed message", text: "Taylor · Today · Review the agenda.", evidence: "EVIDENCE for first message"),
                ReadingItem(id: "two", title: "Second observed message", text: "Morgan · Yesterday · Meeting moved.", evidence: "EVIDENCE for second message")
            ], coverage: .complete,
                coverageNotes: (1...7).map { "LONG NOTE \($0): " + String(repeating: "Observed collection detail. ", count: 100) },
                accountEvidence: "Account EVIDENCE", sourceEvidence: "Source EVIDENCE", scopeEvidence: "Coverage EVIDENCE")
            entry = SourceRunEntry(reading: request, state: .complete)
            entry.readingSnapshot = snapshot
        }
    }
}
