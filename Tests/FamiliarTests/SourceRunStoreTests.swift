import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct SourceRunStoreTests {
    @Test func repeatedReadsRetainBothTimestampedReportsOutsideRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-runs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CalendarStore(directory: root)
        let source = LearnedReadingSource(name: "Inbox", meaning: "Incoming messages", url: "https://mail.example.test/inbox", scope: "Visible inbox")
        try store.saveReadingSource(source)
        for text in ["First observation", "Second observation"] {
            try store.saveReadingSnapshot(ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
                items: [ReadingItem(id: text, title: text, text: text, evidence: "Visible row")], coverage: .complete,
                accountEvidence: "Current account", sourceEvidence: "Inbox", scopeEvidence: "Visible inbox"))
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("runs"), includingPropertiesForKeys: nil)) ?? []
        #expect(folders.count == 2)
        let reports = folders.compactMap { try? String(contentsOf: $0.appendingPathComponent("report.md"), encoding: .utf8) }.joined(separator: "\n")
        #expect(reports.contains("First observation"))
        #expect(reports.contains("Second observation"))
        let rules = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("workspace.json"))) as? [String: Any])
        #expect(rules["snapshots"] == nil)
        #expect(rules["readingSnapshots"] == nil)
        let reopened = CalendarStore(directory: root)
        #expect(reopened.runStore.runs.count == 2)
        #expect(reopened.latestReading(for: source.id)?.items.first?.text == "Second observation")
    }

    @Test func restartMarksOnlyUnfinishedRowsInterruptedAndPreservesSuccessfulRows() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = SourceRunStore(directory: fixture.root)
        var completed = fixture.entry("Completed")
        completed.state = .complete
        completed.readingSnapshot = fixture.snapshot(completed)
        completed.message = "Collected one item."
        var reading = fixture.entry("Reading")
        reading.state = .reading; reading.message = "Reading fresh source information."
        var waiting = fixture.entry("Waiting")
        waiting.message = "Waiting to collect."
        let run = try store.begin(entries: [completed, reading, waiting], origin: .all)
        let reopened = SourceRunStore(directory: fixture.root)
        let recovered = try #require(reopened.run(id: run.id))
        #expect(recovered.status == .interrupted)
        #expect(recovered.entries[0] == completed)
        #expect(recovered.entries[1].state == .interrupted)
        #expect(recovered.entries[1].message.contains("Interrupted"))
        #expect(recovered.entries[2].state == .notRun)
        #expect(recovered.entries[2].message.contains("Not run"))
        #expect(SourceRunStore(directory: fixture.root).run(id: run.id) == recovered)
    }

    @Test func completeRunKeepsExactDatesPrivateFilesReadableFolderAndDerivedExports() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = SourceRunStore(directory: fixture.root)
        let timestamp = Date(timeIntervalSinceReferenceDate: 812_345_678.1234567)
        var entry = fixture.entry("Inbox / Primary")
        entry.requestedAt = timestamp
        let run = try store.begin(entries: [entry], origin: .single, startedAt: timestamp, timeZoneID: "America/New_York")
        entry.state = .partial; entry.readingSnapshot = fixture.snapshot(entry, partial: true)
        try store.updateEntry(runID: run.id, entry: entry)
        let finished = try store.finish(runID: run.id, status: .completed, finishedAt: timestamp.addingTimeInterval(40))
        let folder = try #require(store.directory(for: run.id))
        #expect(folder.lastPathComponent.count == 19)
        #expect(SourceRunStore(directory: fixture.root).run(id: run.id) == finished)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 3)
        for file in files {
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let text = try String(contentsOf: folder.appendingPathComponent("run.json"), encoding: .utf8)
        #expect(text.contains("America/New_York"))
        #expect(text.contains("T") && text.contains("Z"))
        let report = try #require(store.report(for: run.id))
        #expect(report.contains("Observation") && report.contains("Unseen rows"))
        #expect(!report.contains("PRIVATE NAVIGATION RULES"))
    }

    @Test func sameSecondRunsGetSeparateFoldersAndFailuresLeaveLastCommittedState() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = SourceRunStore(directory: fixture.root)
        let time = Date()
        let first = try store.begin(entries: [fixture.entry("First")], origin: .single, startedAt: time)
        let second = try store.begin(entries: [fixture.entry("Second")], origin: .single, startedAt: time)
        #expect(store.directory(for: first.id) != store.directory(for: second.id))
        let previous = try #require(store.directory(for: first.id)).appendingPathComponent("run.json")
        let bytes = try Data(contentsOf: previous)
        let backup = fixture.root.appendingPathExtension("backup")
        defer { try? FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: fixture.root, to: backup)
        try Data("Blocked".utf8).write(to: fixture.root)
        #expect(throws: (any Error).self) { try store.finish(runID: first.id, status: .stopped) }
        #expect(store.run(id: first.id) == first)
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.moveItem(at: backup, to: fixture.root)
        #expect(try Data(contentsOf: previous) == bytes)
    }

    @Test func migrationPreservesActiveAndRemovedHistoryAndDoesNotRepeatAfterRetry() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let active = fixture.entry("Active"), removed = fixture.entry("Removed")
        struct Legacy: Encodable {
            var version = 3
            var sources: [LearnedCalendarSource] = []
            var snapshots: [CalendarSnapshot] = []
            var readingSources: [LearnedReadingSource]
            var readingSnapshots: [ReadingSnapshot]
            var removedSources: [RemovedSource]
        }
        let activeSnapshot = fixture.snapshot(active), removedSnapshot = fixture.snapshot(removed)
        let legacy = Legacy(readingSources: [active.readingSource!], readingSnapshots: [activeSnapshot],
            removedSources: [RemovedSource(id: removed.sourceID, reading: removed.readingSource, readingSnapshots: [removedSnapshot])])
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let file = fixture.root.appendingPathComponent("workspace.json")
        let bytes = try JSONEncoder().encode(legacy)
        try bytes.write(to: file)
        let store = CalendarStore(directory: fixture.root)
        #expect(store.error == nil)
        #expect(store.runStore.runs.count == 2)
        #expect(store.runStore.runs.allSatisfy { $0.origin == .migration })
        #expect(store.latestReading(for: active.sourceID) == activeSnapshot)
        #expect(store.removedSources.first?.readingSnapshots == [removedSnapshot])
        let rules = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let removedRules = try #require(rules["removedSources"] as? [[String: Any]])
        #expect(removedRules[0]["readingSnapshots"] == nil)
        // Simulate a crash after archive commits but before the legacy workspace swap.
        try bytes.write(to: file)
        let retry = CalendarStore(directory: fixture.root)
        #expect(retry.error == nil && retry.runStore.runs.count == 2)
        try retry.restoreSource(id: removed.sourceID)
        #expect(retry.latestReading(for: removed.sourceID) == removedSnapshot)
        try retry.removeSource(id: active.sourceID)
        #expect(retry.runStore.runs.count == 2)
    }

    @Test func corruptOrFutureArchiveCannotBeOverwrittenAndCaptureCannotChange() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = SourceRunStore(directory: fixture.root)
        let entry = fixture.entry("Work")
        let run = try store.begin(entries: [entry], origin: .single)
        var edited = entry; edited.readingSource?.scope = "A different scope"
        #expect(throws: CalendarDataError.self) { try store.updateEntry(runID: run.id, entry: edited) }
        let file = try #require(store.directory(for: run.id)).appendingPathComponent("run.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 99
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: file)
        let reopened = SourceRunStore(directory: fixture.root)
        #expect(reopened.error != nil)
        #expect(throws: CalendarDataError.self) { try reopened.begin(entries: [entry], origin: .single) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func failedMigrationLeavesLegacyWorkspaceUntouchedUntilArchiveIsWritable() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let entry = fixture.entry("Inbox")
        let snapshot = fixture.snapshot(entry)
        struct Legacy: Encodable {
            var version = 2
            var sources: [LearnedCalendarSource] = []
            var snapshots: [CalendarSnapshot] = []
            var readingSources: [LearnedReadingSource]
            var readingSnapshots: [ReadingSnapshot]
        }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let file = fixture.root.appendingPathComponent("workspace.json")
        let runs = fixture.root.appendingPathComponent("runs")
        let bytes = try JSONEncoder().encode(Legacy(readingSources: [entry.readingSource!], readingSnapshots: [snapshot]))
        try bytes.write(to: file)
        try Data("Blocked".utf8).write(to: runs)
        let failed = CalendarStore(directory: fixture.root)
        #expect(failed.error != nil)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: CalendarDataError.self) { try failed.saveReadingSource(entry.readingSource!) }
        try FileManager.default.removeItem(at: runs)
        let retry = CalendarStore(directory: fixture.root)
        #expect(retry.error == nil)
        #expect(retry.latestReading(for: entry.sourceID) == snapshot)
        #expect(retry.runStore.runs.count == 1)
    }

    @Test func legacyRetryPreservesTheFirstImportedDisplayTimeZone() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let snapshot = fixture.snapshot(fixture.entry("Inbox"))
        let store = SourceRunStore(directory: fixture.root)
        try store.importLegacy(reading: snapshot)
        var record = try #require(store.runs.first)
        record.timeZoneID = TimeZone.current.identifier == "Asia/Tokyo" ? "America/New_York" : "Asia/Tokyo"
        let folder = try #require(store.directory(for: record.id))
        try SourceRunJSON.encoder().encode(record).write(to: folder.appendingPathComponent("run.json"))
        let reopened = SourceRunStore(directory: fixture.root)
        try reopened.importLegacy(reading: snapshot)
        #expect(reopened.runs == [record])
        #expect(reopened.directory(for: record.id)?.resolvingSymlinksInPath().standardizedFileURL.path
            == folder.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-archive-\(UUID())")
        func remove() { try? FileManager.default.removeItem(at: root) }
        func entry(_ name: String) -> SourceRunEntry {
            SourceRunEntry(reading: ReadingReadRequest(source: LearnedReadingSource(name: name, meaning: "Incoming information", url: "https://example.test/inbox", scope: "Visible rows", navigationHints: "PRIVATE NAVIGATION RULES")))
        }
        func snapshot(_ entry: SourceRunEntry, partial: Bool = false) -> ReadingSnapshot {
            ReadingSnapshot(requestID: entry.id, sourceID: entry.sourceID, source: entry.readingSource!,
                items: [ReadingItem(id: "one", title: "Observation", text: "Collected information", evidence: "Visible row")], coverage: partial ? .partial : .complete,
                coverageNotes: partial ? ["Unseen rows"] : [], accountEvidence: "Visible account", sourceEvidence: "Visible inbox", scopeEvidence: "Visible rows")
        }
    }
}
