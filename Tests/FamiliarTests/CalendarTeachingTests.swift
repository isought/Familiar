import Foundation
import Testing
@testable import Familiar

@Suite
struct CalendarTeachingTests {
    @Test
    func ordinaryDraftsStayCompatibleWithoutASource() throws {
        let draft = WatchSummarizer.parse(try reply(), recording: recording())
        #expect(draft.parsed)
        #expect(draft.workflowTitle == "Read the calendar")
        #expect(draft.calendarSource == nil)
    }

    @Test
    func observedCalendarLocationIsSavedSeparatelyFromGenericPackMatches() throws {
        let source = sourceJSON()
        let draft = WatchSummarizer.parse(try reply(source: source), recording: recording())
        let learned = try #require(draft.calendarSource)
        #expect(learned.name == "Work calendar")
        #expect(learned.url == calendarURL)
        #expect(learned.account == "dana@example.test")
        #expect(learned.calendarName == "Work")
        #expect(learned.timeZoneID == "America/New_York")
        #expect(learned.workflowPath == draft.packDir + "/docs/workflows/" + draft.workflowSlug + ".md")
        #expect(!draft.matchURLs.contains("calendar.google.com"))
        #expect(!draft.matchTitles.isEmpty)
        try learned.validate()
    }

    @Test
    func aDisplayedURLResolvesOnlyToTheObservedLocation() throws {
        var source = sourceJSON()
        source["url"] = WatchSummarizer.shortURL(calendarURL)
        let draft = WatchSummarizer.parse(try reply(source: source), recording: recording())
        #expect(draft.calendarSource?.url == calendarURL)

        source["url"] = "https://calendar.google.com/calendar/u/1/r/day"
        let invented = WatchSummarizer.parse(try reply(source: source), recording: recording())
        #expect(invented.calendarSource == nil)
        #expect(invented.caveats.contains { $0.contains("No calendar source was learned") })
    }

    @Test
    func incompleteNativeSourceRetainsUnknownsWithoutInventingAccountOrTimeZone() throws {
        let native = Recording(dir: URL(fileURLWithPath: "/unused-calendar-teaching"),
                               events: [WatchEvent(index: 0, t: 0, kind: "click", app: "Calendar", label: "Day")],
                               meta: WatchMeta(startedAt: "2026-09-28", apps: ["Calendar"], bundles: ["com.apple.iCal"]))
        let source: [String: Any] = ["name": "My calendar", "meaning": "My schedule", "application": "Calendar",
                                     "bundle_id": "com.apple.iCal", "uncertainties": ["The account and time zone were not shown."]]
        let draft = WatchSummarizer.parse(try reply(source: source), recording: native)
        let learned = try #require(draft.calendarSource)
        #expect(learned.account.isEmpty)
        #expect(learned.calendarName.isEmpty)
        #expect(learned.timeZoneID.isEmpty)
        #expect(learned.url.isEmpty)
        #expect(learned.uncertainties == ["The account and time zone were not shown."])
        try learned.validate()
    }

    @Test
    func unobservedApplicationIdentifiersAndInvalidTimeZonesAreNotTrusted() throws {
        var source = sourceJSON()
        source["bundle_id"] = "com.unobserved.calendar"
        source["application"] = "Unobserved calendar"
        source["time_zone_id"] = "Mars/Olympus"
        let draft = WatchSummarizer.parse(try reply(source: source), recording: recording())
        let learned = try #require(draft.calendarSource)
        #expect(learned.url == calendarURL)
        #expect(learned.bundleID.isEmpty)
        #expect(learned.application.isEmpty)
        #expect(learned.timeZoneID.isEmpty)
        #expect(learned.uncertainties.count == 3)
        try learned.validate()
    }

    @Test
    @MainActor
    func fullDraftShowsEverySemanticFieldAndUnknownsBeforeKeep() throws {
        var source = sourceJSON()
        source["account"] = ""
        source["uncertainties"] = ["Account was not shown."]
        let draft = WatchSummarizer.parse(try reply(source: source), recording: recording())
        let body = Assistant.draftDocument(draft, root: URL(fileURLWithPath: "/unused-tools"), teachingCalendar: true)
        for label in ["Name", "Meaning", "Application", "Application identifier", "Location", "Account", "Calendar", "Time zone", "Navigation", "Completion checks", "Still unclear"] {
            #expect(body.contains("**\(label):**"))
        }
        #expect(body.contains("**Account:** Not established"))
        #expect(body.contains("Account was not shown."))
        #expect(body.contains("demonstrated dates and events are examples"))
    }

    private var calendarURL: String { "https://calendar.google.com/calendar/u/0/r/day" }

    private func recording() -> Recording {
        Recording(dir: URL(fileURLWithPath: "/unused-calendar-teaching"),
                  events: [WatchEvent(index: 0, t: 0, kind: "scene", app: "Google Chrome", title: "Work - Google Calendar", url: calendarURL),
                           WatchEvent(index: 1, t: 1, kind: "click", app: "Google Chrome", title: "Work - Google Calendar", url: calendarURL, label: "Day")],
                  meta: WatchMeta(startedAt: "2026-09-28", hosts: ["calendar.google.com"], titles: ["Work - Google Calendar"],
                                  apps: ["Google Chrome"], bundles: ["com.google.Chrome"]))
    }

    private func sourceJSON() -> [String: Any] {
        ["name": "Work calendar", "meaning": "My work schedule", "application": "Google Chrome",
         "bundle_id": "com.google.Chrome", "url": calendarURL, "account": "dana@example.test",
         "calendar_name": "Work", "time_zone_id": "America/New_York",
         "navigation_hints": "Select Day, then the requested date.",
         "completion_checks": "Check the account, calendar selection, date heading, and the full day.",
         "uncertainties": []]
    }

    private func reply(source: [String: Any]? = nil) throws -> String {
        var json: [String: Any] = ["pack_name": "Calendar", "match_urls": ["calendar.google.com"],
                                   "workflow_title": "Read the calendar", "workflow_markdown": "1. Choose Day.\n2. Read the events."]
        if let source { json["calendar_source"] = source }
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
}
