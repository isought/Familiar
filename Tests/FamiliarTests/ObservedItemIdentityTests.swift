import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct ObservedItemIdentityTests {
    @Test func stableThreadIdentitySurvivesChangedSnippetAndResolution() throws {
        let request = readingRequest()
        var row: [String: Any] = ["title": "Review the plan", "text": "Taylor: please review", "evidence": "Fresh row",
            "identityKey": "thread:abc123", "identityEvidence": "Visible thread permalink abc123",
            "observedState": "open", "stateEvidence": "Taylor requests a review"]
        let first = try ReadingSubmission.parse(readingPayload(request, rows: [row]), request: request)
        row["text"] = "Alex: reviewed and approved; Taylor: thanks, complete"
        row["observedState"] = "resolved"
        row["stateEvidence"] = "Visible reply from Alex and completion acknowledgment from Taylor"
        let next = ReadingReadRequest(source: request.source)
        let second = try ReadingSubmission.parse(readingPayload(next, rows: [row]), request: next)
        #expect(first.items.first?.id == second.items.first?.id)
        #expect(first.items.first?.identityKey == second.items.first?.identityKey)
        #expect(first.items.first?.text != second.items.first?.text)
        #expect(second.items.first?.observedState == .resolved)
        row.removeValue(forKey: "stateEvidence")
        #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(readingPayload(next, rows: [row]), request: next) }
    }

    @Test func oldReadingAndCalendarItemsDecodeWithoutNewMetadata() throws {
        let reading = ReadingItem(id: "legacy", title: "Old subject", text: "Old snippet", evidence: "Old row")
        let decoder = JSONDecoder()
        let restored = try decoder.decode(ReadingItem.self, from: JSONEncoder().encode(reading))
        #expect(restored == reading)
        #expect(restored.identityKey == nil && restored.observedState == nil)
        let event = CalendarEventRecord(id: "old-event", title: "Review", start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000), evidence: "Old event")
        let restoredEvent = try decoder.decode(CalendarEventRecord.self, from: JSONEncoder().encode(event))
        #expect(restoredEvent == event)
        #expect(restoredEvent.identityKey == nil && restoredEvent.observedState == nil)
    }

    @Test func calendarIdentitySurvivesTimeChangeAndCancellationIsResolved() throws {
        let source = LearnedCalendarSource(name: "Work", meaning: "Meetings", application: "Calendar",
            account: "alex@example.test", calendarName: "Work", timeZoneID: "UTC")
        let request = CalendarReadRequest(source: source, day: try CalendarSubmission.timestamp("2026-09-28T09:00:00Z"))
        var event: [String: Any] = ["title": "Planning", "start": "2026-09-28T09:00:00Z", "end": "2026-09-28T10:00:00Z",
            "allDay": false, "response": "accepted", "availability": "busy", "isCancelled": false,
            "evidence": "Planning 9–10", "identityKey": "event:planning-123", "identityEvidence": "Visible event ID planning-123"]
        func payload() -> [String: Any] {
            ["sourceID": source.id.uuidString, "day": request.dateLabel, "timeZoneID": "UTC", "coverage": "complete",
             "coverageNotes": [], "accountEvidence": "Account alex@example.test", "calendarEvidence": "Work calendar",
             "dateEvidence": "Sep 28, UTC", "events": [event]]
        }
        let first = try CalendarSubmission.parse(payload(), request: request)
        event["start"] = "2026-09-28T11:00:00Z"
        event["end"] = "2026-09-28T12:00:00Z"
        event["isCancelled"] = true
        event["evidence"] = "Event explicitly marked Cancelled"
        let second = try CalendarSubmission.parse(payload(), request: request)
        #expect(first.events.first?.id == second.events.first?.id)
        #expect(second.events.first?.observedState == .resolved)
        #expect(second.events.first?.stateEvidence == "Event explicitly marked Cancelled")
    }

    @Test func trackedFollowUpPolicyOpensOnlyMatchingRowsAndExposesNoMutationTools() async throws {
        let tracked = TrackedSourceItem(key: "thread:abc123", title: "Project agenda", details: "Awaiting review", url: "", identityEvidence: "Original sender and subject")
        #expect(ReadingNavigationPolicy.followUpRefusal(.init(role: "AXRow", title: "Taylor, Project agenda, yesterday"), trackedItems: [tracked]) == nil)
        #expect(ReadingNavigationPolicy.followUpRefusal(.init(role: "AXCell", title: "Project agenda"), trackedItems: [tracked]) == nil)
        for label in ["Inbox", "All Mail", "Sent", "Sent Mail", "Back to inbox"] {
            #expect(ReadingNavigationPolicy.followUpRefusal(.init(role: "AXButton", title: label), trackedItems: [tracked]) == nil)
        }
        #expect(ReadingNavigationPolicy.refusal(.init(role: "AXRow", title: "Project agenda")) != nil)
        #expect(ReadingNavigationPolicy.followUpRefusal(.init(role: "AXRow", title: "Unrelated thread"), trackedItems: [tracked]) != nil)
        for role in ["AXButton", "AXLink", "AXCheckBox", "AXTextField"] {
            #expect(ReadingNavigationPolicy.followUpRefusal(.init(role: role, title: "Project agenda"), trackedItems: [tracked]) != nil)
        }
        for label in ["Reply", "Reply all", "Compose", "Send", "Archive", "Delete", "Mark as unread"] {
            #expect(ReadingNavigationPolicy.followUpRefusal(.init(role: "AXButton", title: label), trackedItems: [tracked]) != nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ComputerController()
        let registry = ToolRegistry(root: directory, runner: ScriptRunner(config: Config()))
        let router = try ExecutionTools.make(registry: registry, context: nil, control: control, background: true,
            policy: .sourceFollowUp, trackedItems: [tracked], lookAtScreen: { .text("Unused") })
        let names = Set(router.definitions.compactMap { $0["name"] as? String })
        #expect(names == ["target_window", "read_screen", "look_at_screen", "find_on_screen", "click_element", "reading_scroll"])
    }

    @Test func trackedObservationAllowanceDoesNotExpandDiscoveryLimit() throws {
        let request = readingRequest()
        let tracked = TrackedSourceItem(key: "thread:old", title: "Old conversation", details: "Needs response", url: "", identityEvidence: "Original sender")
        let newRows: [[String: Any]] = (0..<ReadingSubmission.itemLimit).map { ["title": "New \($0)", "text": "Snippet \($0)", "evidence": "Visible row"] }
        let followed: [String: Any] = ["title": tracked.title, "text": "Reply is visible", "evidence": "Fresh thread",
            "identityKey": tracked.key, "identityEvidence": "Matched original sender and subject", "observedState": "unknown"]
        let result = try ReadingSubmission.parse(readingPayload(request, rows: newRows + [followed]), request: request, trackedItems: [tracked])
        #expect(result.items.count == 26)
        #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(readingPayload(request, rows: newRows + [followed]), request: request) }
        let unrelated: [String: Any] = ["title": "Unrelated older mail", "text": "Another snippet", "evidence": "Visible row"]
        #expect(throws: CalendarDataError.self) { try ReadingSubmission.parse(readingPayload(request, rows: newRows + [unrelated]), request: request, trackedItems: [tracked]) }
    }

    @Test func missingTrackedItemCannotBeReportedAsCompleteOrResolved() throws {
        let request = readingRequest()
        let tracked = TrackedSourceItem(key: "thread:old", title: "Pending review", details: "Needs review", url: "", identityEvidence: "Original subject")
        let snapshot = try ReadingSubmission.parse(readingPayload(request, rows: []), request: request, trackedItems: [tracked])
        #expect(snapshot.coverage == .partial)
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.coverageNotes.contains { $0.contains("Pending review") && $0.contains("unresolved") })
    }

    private func readingRequest() -> ReadingReadRequest {
        ReadingReadRequest(source: LearnedReadingSource(kind: .mail, name: "Work", meaning: "Incoming requests",
            application: "Chrome", url: "https://mail.example.test/inbox", account: "alex@example.test", scope: "Unread from last two days"))
    }
    private func readingPayload(_ request: ReadingReadRequest, rows: [[String: Any]]) -> [String: Any] {
        ["sourceID": request.source.id.uuidString, "requestID": request.id.uuidString, "coverage": "complete", "coverageNotes": [],
         "accountEvidence": "alex@example.test", "sourceEvidence": "Saved inbox URL", "scopeEvidence": "Unread dates checked", "items": rows]
    }
}
