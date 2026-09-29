import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct SourceManagementTests {
    @Test func removingCalendarAndMailArchivesTheirResultsAndRestoresThemAfterRestart() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let calendar = fixture.calendar()
        let mail = fixture.reading()
        let unrelated = fixture.calendar(name: "Personal")
        try fixture.store.saveSource(calendar)
        try fixture.store.saveSource(unrelated)
        try fixture.store.saveReadingSource(mail)
        let firstDay = fixture.calendarSnapshot(calendar)
        let secondDay = fixture.calendarSnapshot(calendar, dayOffset: 1)
        let personal = fixture.calendarSnapshot(unrelated)
        let inbox = fixture.readingSnapshot(mail)
        for snapshot in [firstDay, secondDay, personal] { try fixture.store.saveSnapshot(snapshot) }
        try fixture.store.saveReadingSnapshot(inbox)

        try fixture.store.removeSource(id: calendar.id)
        try fixture.store.removeSource(id: mail.id)
        #expect(fixture.store.sources == [unrelated])
        #expect(fixture.store.snapshots == [personal])
        #expect(fixture.store.readingSources.isEmpty && fixture.store.readingSnapshots.isEmpty)
        #expect(fixture.store.removedSources.map(\.id) == [calendar.id, mail.id])
        #expect(fixture.store.removedSources.first?.calendarSnapshots == [firstDay, secondDay])
        #expect(fixture.store.removedSources.last?.readingSnapshots == [inbox])
        #expect(fixture.store.latest(for: calendar.id) == nil && fixture.store.latestReading(for: mail.id) == nil)

        let reopened = CalendarStore(directory: fixture.directory)
        #expect(reopened.error == nil)
        #expect(reopened.removedSources == fixture.store.removedSources)
        try reopened.restoreSource(id: calendar.id)
        try reopened.restoreSource(id: mail.id)
        #expect(reopened.removedSources.isEmpty)
        #expect(reopened.sources.first { $0.id == calendar.id } == calendar)
        #expect(reopened.readingSources == [mail])
        #expect(reopened.snapshots.filter { $0.sourceID == calendar.id } == [firstDay, secondDay])
        #expect(reopened.readingSnapshots == [inbox])
        #expect(reopened.sources.first { $0.id == unrelated.id } == unrelated)
        let restored = CalendarStore(directory: fixture.directory)
        #expect(restored.sources == reopened.sources && restored.readingSnapshots == [inbox])
        #expect(restored.removedSources.isEmpty)
    }

    @Test func updatingAnExistingSourceKeepsItsIdentityAndNeverAddsADuplicate() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var calendar = fixture.calendar()
        var mail = fixture.reading()
        try fixture.store.saveSource(calendar)
        try fixture.store.saveReadingSource(mail)
        calendar.name = "Updated work calendar"
        calendar.navigationHints = "Use the new date heading"
        mail.name = "Updated inbox"
        mail.scope = "The first ten visible rows"
        try fixture.store.saveSource(calendar)
        try fixture.store.saveReadingSource(mail)
        #expect(fixture.store.sources == [calendar])
        #expect(fixture.store.readingSources == [mail])
        #expect(fixture.store.removedSources.isEmpty)
    }

    @Test func lateEditsAndInFlightResultsCannotSilentlyRestoreRemovedSources() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let calendar = fixture.calendar()
        let mail = fixture.reading()
        try fixture.store.saveSource(calendar)
        try fixture.store.saveReadingSource(mail)
        try fixture.store.removeSource(id: calendar.id)
        try fixture.store.removeSource(id: mail.id)
        let before = try Data(contentsOf: fixture.file)
        #expect(throws: CalendarDataError.self) { try fixture.store.saveSource(calendar) }
        #expect(throws: CalendarDataError.self) { try fixture.store.saveReadingSource(mail) }
        #expect(throws: CalendarDataError.self) { try fixture.store.saveSnapshot(fixture.calendarSnapshot(calendar)) }
        #expect(throws: CalendarDataError.self) { try fixture.store.saveReadingSnapshot(fixture.readingSnapshot(mail)) }
        #expect(try Data(contentsOf: fixture.file) == before)
        #expect(fixture.store.sources.isEmpty && fixture.store.readingSources.isEmpty)
        #expect(fixture.store.removedSources.count == 2)
        var newTeaching = mail
        newTeaching.id = UUID()
        try fixture.store.saveReadingSource(newTeaching)
        #expect(fixture.store.readingSources == [newTeaching])
        #expect(fixture.store.removedSources.count == 2)
    }

    @Test func failedRemovalAndRestoreLeavePublishedAndPersistedStateIntact() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let source = fixture.reading()
        let snapshot = fixture.readingSnapshot(source)
        try fixture.store.saveReadingSource(source)
        try fixture.store.saveReadingSnapshot(snapshot)
        let original = try Data(contentsOf: fixture.file)
        try fixture.blockWrites()
        #expect(throws: (any Error).self) { try fixture.store.removeSource(id: source.id) }
        #expect(fixture.store.readingSources == [source] && fixture.store.readingSnapshots == [snapshot])
        #expect(fixture.store.removedSources.isEmpty)
        #expect(try Data(contentsOf: fixture.backup) == original)
        try fixture.unblockWrites()
        try fixture.store.removeSource(id: source.id)
        let removed = fixture.store.removedSources
        let archivedBytes = try Data(contentsOf: fixture.file)
        try fixture.blockWrites()
        #expect(throws: (any Error).self) { try fixture.store.restoreSource(id: source.id) }
        #expect(fixture.store.readingSources.isEmpty && fixture.store.readingSnapshots.isEmpty)
        #expect(fixture.store.removedSources == removed)
        #expect(try Data(contentsOf: fixture.backup) == archivedBytes)
        try fixture.unblockWrites()
        #expect(CalendarStore(directory: fixture.directory).removedSources == removed)
    }

    @Test func restoreWorkflowAndSnapshotCollisionsFailWithoutChangingEitherSource() throws {
        for collideByWorkflow in [true, false] {
            let fixture = Fixture()
            defer { fixture.remove() }
            var original = fixture.calendar()
            if collideByWorkflow { original.workflowPath = "work/docs/workflows/calendar.md" }
            try fixture.store.saveSource(original)
            let snapshot = fixture.calendarSnapshot(original)
            try fixture.store.saveSnapshot(snapshot)
            try fixture.store.removeSource(id: original.id)
            var replacement = fixture.calendar(name: "Another calendar")
            replacement.workflowPath = original.workflowPath
            try fixture.store.saveSource(replacement)
            if !collideByWorkflow {
                var conflicting = fixture.calendarSnapshot(replacement)
                conflicting.id = snapshot.id
                try fixture.store.saveSnapshot(conflicting)
            }
            let bytes = try Data(contentsOf: fixture.file)
            #expect(throws: CalendarDataError.self) { try fixture.store.restoreSource(id: original.id) }
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(fixture.store.sources == [replacement])
            #expect(fixture.store.removedSources.first?.calendar == original)
        }
    }

    @Test func removedWorkflowsNeverReappearAndTheirOriginalFilesStayUntouched() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let workflow = try fixture.writeWorkflow(name: "Read Primary", file: "inbox.md")
        let original = try Data(contentsOf: workflow)
        fixture.store.refreshSavedWorkflows(root: fixture.tools)
        var source = try #require(fixture.store.savedReadingWorkflows.first?.draft)
        source.requiresReview = false
        source.id = UUID() // New Watch Me registrations use an unrelated UUID but retain their actual workflow path.
        try fixture.store.saveReadingSource(source)
        #expect(fixture.store.savedReadingWorkflows.isEmpty)
        try fixture.store.removeSource(id: source.id)
        #expect(fixture.store.savedReadingWorkflows.isEmpty)
        let reopened = CalendarStore(directory: fixture.directory)
        reopened.refreshSavedWorkflows(root: fixture.tools)
        #expect(reopened.savedReadingWorkflows.isEmpty)
        #expect(reopened.removedSources.first?.reading == source)
        #expect(try Data(contentsOf: workflow) == original)
        try reopened.restoreSource(id: source.id)
        #expect(reopened.savedReadingWorkflows.isEmpty)
        #expect(try Data(contentsOf: workflow) == original)
    }

    @Test func recoveredIdentityAndCalendarWorkflowPathAlsoSuppressRemovedSuggestions() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeWorkflow(name: "Read Primary", file: "inbox.md")
        _ = try fixture.writeWorkflow(name: "Read calendar", file: "calendar.md")
        fixture.store.refreshSavedWorkflows(root: fixture.tools)
        var recovered = try #require(fixture.store.savedReadingWorkflows.first { $0.relativePath.hasSuffix("inbox.md") }?.draft)
        recovered.requiresReview = false
        recovered.workflowPath = "" // An older imported profile may have only its stable recovered UUID.
        try fixture.store.saveReadingSource(recovered)
        var calendar = fixture.calendar()
        calendar.workflowPath = "sample/docs/workflows/calendar.md"
        try fixture.store.saveSource(calendar)
        #expect(fixture.store.savedReadingWorkflows.isEmpty)
        try fixture.store.removeSource(id: recovered.id)
        try fixture.store.removeSource(id: calendar.id)
        let reopened = CalendarStore(directory: fixture.directory)
        reopened.refreshSavedWorkflows(root: fixture.tools)
        #expect(reopened.savedReadingWorkflows.isEmpty)
        #expect(reopened.removedSources.count == 2)
    }

    @Test func legacyWorkspacesMigrateAllObservationsBeforeRemovingEmbeddedResults() throws {
        for version in [1, 2] {
            let fixture = Fixture()
            defer { fixture.remove() }
            let calendar = fixture.calendar()
            let mail = fixture.reading()
            struct Legacy: Encodable {
                var version: Int
                var sources: [LearnedCalendarSource]
                var snapshots: [CalendarSnapshot]
                var readingSources: [LearnedReadingSource]?
                var readingSnapshots: [ReadingSnapshot]?
            }
            let legacy = Legacy(version: version, sources: [calendar], snapshots: [fixture.calendarSnapshot(calendar)],
                                readingSources: version == 2 ? [mail] : nil,
                                readingSnapshots: version == 2 ? [fixture.readingSnapshot(mail)] : nil)
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
            let original = try JSONEncoder().encode(legacy)
            try original.write(to: fixture.file)
            let store = CalendarStore(directory: fixture.directory)
            #expect(store.error == nil && store.removedSources.isEmpty)
            #expect(store.sources == [calendar])
            #expect(store.readingSources == (version == 2 ? [mail] : []))
            #expect(store.runStore.runs.count == (version == 2 ? 2 : 1))
            #expect(store.snapshots == legacy.snapshots)
            #expect(store.readingSnapshots == (legacy.readingSnapshots ?? []))
            try store.removeSource(id: calendar.id)
            let updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any])
            #expect(updated["version"] as? Int == 4)
            #expect((updated["removedSources"] as? [Any])?.count == 1)
            #expect(store.readingSources == (version == 2 ? [mail] : []))
        }
    }

    @Test func malformedVersionThreeArchiveIsProtectedAndUnknownRemovalsDoNotWrite() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let source = fixture.calendar()
        try fixture.store.saveSource(source)
        let original = try Data(contentsOf: fixture.file)
        #expect(throws: CalendarDataError.self) { try fixture.store.removeSource(id: UUID()) }
        #expect(throws: CalendarDataError.self) { try fixture.store.restoreSource(id: UUID()) }
        #expect(try Data(contentsOf: fixture.file) == original)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object.removeValue(forKey: "removedSources")
        let malformed = try JSONSerialization.data(withJSONObject: object)
        try malformed.write(to: fixture.file)
        let reopened = CalendarStore(directory: fixture.directory)
        #expect(reopened.error != nil)
        #expect(throws: CalendarDataError.self) { try reopened.saveSource(source) }
        #expect(try Data(contentsOf: fixture.file) == malformed)
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-management-\(UUID().uuidString)")
        var directory: URL { root.appendingPathComponent("sources") }
        var file: URL { directory.appendingPathComponent("workspace.json") }
        var backup: URL { directory.appendingPathComponent("workspace-backup.json") }
        var tools: URL { root.appendingPathComponent("tools") }
        lazy var store = CalendarStore(directory: directory)
        func remove() { try? FileManager.default.removeItem(at: root) }
        func calendar(name: String = "Work") -> LearnedCalendarSource {
            LearnedCalendarSource(name: name, meaning: "My meeting schedule", application: "Calendar", bundleID: "example.calendar",
                                  account: "alex@example.test", calendarName: name, timeZoneID: "America/New_York")
        }
        func reading() -> LearnedReadingSource {
            LearnedReadingSource(kind: .mail, name: "Inbox", meaning: "My incoming mail", application: "Google Chrome",
                                 url: "https://mail.google.com/mail/u/0/#inbox", account: "alex@example.test", scope: "Read the first inbox page")
        }
        func calendarSnapshot(_ source: LearnedCalendarSource, dayOffset: Int = 0) -> CalendarSnapshot {
            let day = try! CalendarSubmission.timestamp("2026-09-28T00:00:00-04:00").addingTimeInterval(Double(dayOffset) * 86400)
            return CalendarSnapshot(sourceID: source.id, day: day, timeZoneID: source.timeZoneID, events: [], coverage: .complete,
                                    accountEvidence: "Visible account alex@example.test", calendarEvidence: "Work calendar selected",
                                    dateEvidence: "Requested date heading visible", source: source)
        }
        func readingSnapshot(_ source: LearnedReadingSource) -> ReadingSnapshot {
            ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
                            items: [ReadingItem(id: "message", title: "Agenda", text: "The agenda is ready", evidence: "Visible message row")],
                            coverage: .complete, accountEvidence: "Visible account alex@example.test",
                            sourceEvidence: "Inbox at saved URL", scopeEvidence: "First page inspected")
        }
        func blockWrites() throws {
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        func unblockWrites() throws {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
        }
        func writeWorkflow(name: String, file: String) throws -> URL {
            let pack = tools.appendingPathComponent("sample")
            let directory = pack.appendingPathComponent("docs/workflows")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "# Sample\nLearned by watching.".write(to: pack.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let target = directory.appendingPathComponent(file)
            try "# \(name)\nRead the Primary inbox in Google Chrome at `mail.google.com/mail/u/0/#inbox`."
                .write(to: target, atomically: true, encoding: .utf8)
            return target
        }
    }
}
