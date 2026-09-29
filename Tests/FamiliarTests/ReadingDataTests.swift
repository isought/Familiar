import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct ReadingDataTests {
    @Test func sourceURLsAllowInternalSitesButNeverCredentialsOrExecutableSchemes() throws {
        #expect(readingHTTPURL("https://intranet/wiki"))
        #expect(readingHTTPURL("http://jira"))
        #expect(!readingHTTPURL("https://name:password@example.test"))
        #expect(!readingHTTPURL("javascript:alert(1)"))
        #expect(!readingHTTPURL("file:///tmp/data"))
    }

    @Test func calendarWorkspaceUpgradesWithoutLosingSourcesAndPersistsReadingResults() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calendar = LearnedCalendarSource(name: "Work schedule", meaning: "My meetings", application: "Calendar")
        struct Legacy: Encodable { var version = 1; var sources: [LearnedCalendarSource]; var snapshots: [CalendarSnapshot] = [] }
        try JSONEncoder().encode(Legacy(sources: [calendar])).write(to: root.appendingPathComponent("workspace.json"))
        let store = CalendarStore(directory: root)
        #expect(store.sources == [calendar])
        let mail = source()
        try store.saveReadingSource(mail)
        let request = ReadingReadRequest(source: mail)
        let snapshot = try ReadingSubmission.parse(payload(request), request: request)
        try store.saveReadingSnapshot(snapshot)
        let reopened = CalendarStore(directory: root)
        #expect(reopened.error == nil)
        #expect(reopened.sources == [calendar])
        #expect(reopened.readingSources == [mail])
        #expect(reopened.latestReading(for: mail.id) == snapshot)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("workspace.json"))) as? [String: Any]
        #expect(saved?["version"] as? Int == 4)
    }

    @Test func sourceIdentityEditHidesPreviousReadingWithoutRelabelingIt() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CalendarStore(directory: root)
        var mail = source()
        try store.saveReadingSource(mail)
        let request = ReadingReadRequest(source: mail)
        let snapshot = try ReadingSubmission.parse(payload(request), request: request)
        try store.saveReadingSnapshot(snapshot)
        mail.scope = "A different Gmail label"
        try store.saveReadingSource(mail)
        #expect(store.latestReading(for: mail.id) == nil)
        #expect(store.readingSnapshots == [snapshot])
        #expect(store.readingSnapshots.first?.source.scope == request.source.scope)
    }

    @Test func structuredReadRejectsStaleRequestsMissingEvidenceOversizedDataAndUnsupportedLinks() throws {
        let request = ReadingReadRequest(source: source())
        let good = payload(request)
        #expect(try ReadingSubmission.parse(good, request: request).items.count == 1)
        for (key, value) in [("requestID", UUID().uuidString), ("sourceID", UUID().uuidString),
                             ("accountEvidence", ""), ("sourceEvidence", ""), ("scopeEvidence", "")] {
            var changed = good
            changed[key] = value
            #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(changed, request: request) }
        }
        var partial = good
        partial["coverage"] = "partial"
        partial["coverageNotes"] = [] as [String]
        #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(partial, request: request) }
        partial["coverageNotes"] = ["Only the first viewport was readable."]
        #expect(try ReadingSubmission.parse(partial, request: request).coverage == .partial)
        var row = try #require((good["items"] as? [[String: Any]])?.first)
        row["url"] = "javascript:alert(1)"
        var changed = good
        changed["items"] = [row]
        #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(changed, request: request) }
        changed["items"] = Array(repeating: row, count: ReadingSubmission.itemLimit + 1)
        #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(changed, request: request) }
    }

    @Test func duplicatesAreStableButConflictingRowsCannotOverwriteEvidence() throws {
        let request = ReadingReadRequest(source: source())
        var value = payload(request)
        let row = try #require((value["items"] as? [[String: Any]])?.first)
        value["items"] = [row, row]
        let first = try ReadingSubmission.parse(value, request: request)
        #expect(first.items.count == 1)
        let nextRequest = ReadingReadRequest(source: request.source)
        value["requestID"] = nextRequest.id.uuidString
        #expect(try ReadingSubmission.parse(value, request: nextRequest).items.map(\.id) == first.items.map(\.id))
        var one = row, two = row
        one["id"] = "one-message"; two["id"] = "one-message"; two["text"] = "Conflicting observation"
        value["items"] = [one, two]
        #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(value, request: nextRequest) }
    }

    @Test func recoveringKeptGmailOffersReviewAndReusesTheObservedMailboxURL() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools")
        let pack = tools.appendingPathComponent("gmail")
        let workflows = pack.appendingPathComponent("docs/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try "---\nname: Gmail\n---\nLearned by watching. Recordings: 1.".write(to: pack.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Check the Gmail inbox\n1. In Google Chrome, open a New Tab.\n2. Chrome autocompletes `mail.google.com/mail/u/0/#inbox`.\n3. Read the message list on the **Primary** tab.\nNo individual email was opened.".write(to: workflows.appendingPathComponent("check-email-inbox.md"), atomically: true, encoding: .utf8)
        let store = CalendarStore(directory: root.appendingPathComponent("sources"))
        store.refreshSavedWorkflows(root: tools)
        let candidate = try #require(store.savedReadingWorkflows.first)
        #expect(candidate.name == "Check the Gmail inbox")
        #expect(candidate.draft.url == "https://mail.google.com/mail/u/0/#inbox")
        #expect(candidate.draft.kind == .mail)
        #expect(candidate.draft.account.isEmpty)
        #expect(candidate.draft.requiresReview)
        #expect(store.readingSources.isEmpty)
        #expect(throws: CalendarDataError.self) { try candidate.draft.validateForRead() }
        var reviewed = candidate.draft
        reviewed.requiresReview = false
        try reviewed.validateForRead()
        try store.saveReadingSource(reviewed)
        #expect(store.savedReadingWorkflows.isEmpty)
        #expect(CalendarStore(directory: root.appendingPathComponent("sources")).readingSources == [reviewed])
    }

    @Test func brokenVersionTwoWorkspaceIsNotTreatedAsEmpty() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data(#"{"version":2,"sources":[],"snapshots":[]}"#.utf8)
        let file = root.appendingPathComponent("workspace.json")
        try original.write(to: file)
        let store = CalendarStore(directory: root)
        #expect(store.error != nil)
        #expect(throws: (any Error).self) { try store.saveReadingSource(source()) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func unknownAccountAndPartialReadAreDisclosedInBriefing() throws {
        var mail = source()
        mail.account = ""
        let request = ReadingReadRequest(source: mail)
        var input = payload(request)
        input["items"] = [] as [[String: Any]]
        input["coverage"] = "partial"
        input["coverageNotes"] = ["Rows were not readable."]
        let text = ReadingBriefing.render(try ReadingSubmission.parse(input, request: request))
        #expect(text.contains("No account identity was saved"))
        #expect(text.contains("does not establish an empty source"))
        #expect(text.contains("Rows were not readable."))
    }

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reading-data-\(UUID().uuidString)") }
    private func source() -> LearnedReadingSource {
        LearnedReadingSource(kind: .mail, name: "Gmail inbox", meaning: "My incoming mail", application: "Google Chrome",
            bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox", account: "alex@example.test",
            scope: "Read the latest 25 visible Primary inbox rows")
    }
    private func payload(_ request: ReadingReadRequest) -> [String: Any] {
        ["sourceID": request.source.id.uuidString, "requestID": request.id.uuidString,
         "coverage": "complete", "coverageNotes": ["All rows in the saved scope checked."],
         "accountEvidence": "Visible account alex@example.test", "sourceEvidence": "Gmail Inbox at the saved URL",
         "scopeEvidence": "Primary tab, latest visible rows",
         "items": [["title": "Demo agenda", "text": "From Morgan · Today 9:00 AM · The agenda is ready.",
                    "evidence": "Visible row: Morgan, Demo agenda, The agenda is ready, 9:00 AM"]]]
    }
}
