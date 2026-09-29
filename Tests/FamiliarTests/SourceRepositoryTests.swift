import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct SourceRepositoryTests {
    @Test func sourceRulesAndRunHistoryWorkWithoutFileStorage() throws {
        let rules = MemoryRulesRepository()
        let archive = MemoryRunRepository()
        let store = CalendarStore(repository: rules, runStore: SourceRunStore(repository: archive))
        var source = LearnedReadingSource(name: "Inbox", meaning: "Incoming mail", url: "https://mail.example.test/inbox", scope: "Unread mail today")
        try store.saveReadingSource(source)
        let observedSource = source
        let observation = snapshot(source)
        try store.saveReadingSnapshot(observation)
        let recorded = try #require(store.runStore.runs.first)

        source.scope = "Unread mail from the last two days"
        try store.saveReadingSource(source)
        try store.removeSource(id: source.id)
        let savedRules = try #require(rules.contents?.rules)
        #expect(savedRules.readingSources.isEmpty)
        #expect(savedRules.removedSources.first?.readingSnapshots.isEmpty == true)
        #expect(archive.records[recorded.id]?.entries.first?.readingSource == observedSource)

        let reopened = CalendarStore(repository: rules, runStore: SourceRunStore(repository: archive))
        try reopened.restoreSource(id: source.id)
        #expect(reopened.readingSources == [source])
        #expect(reopened.runStore.runs == [recorded])
        #expect(reopened.readingSnapshots == [observation])
        #expect(reopened.runStore.archiveDirectory == nil)
        #expect(reopened.runStore.directory(for: recorded.id) == nil)
        #expect(reopened.runStore.report(for: recorded.id)?.contains("Collected mail") == true)
    }

    @Test func failedRepositoryWritesKeepLastPublishedRulesAndRunState() throws {
        let rules = MemoryRulesRepository()
        let archive = MemoryRunRepository()
        let store = CalendarStore(repository: rules, runStore: SourceRunStore(repository: archive))
        let source = LearnedReadingSource(name: "Inbox", meaning: "Incoming mail", url: "https://mail.example.test/inbox", scope: "Visible rows")
        try store.saveReadingSource(source)
        rules.failWrites = true
        #expect(throws: CalendarDataError.self) { try store.removeSource(id: source.id) }
        #expect(store.readingSources == [source])
        #expect(rules.contents?.rules.readingSources == [source])

        let entry = SourceRunEntry(reading: ReadingReadRequest(source: source))
        let run = try store.runStore.begin(entries: [entry], origin: .single)
        archive.failWrites = true
        #expect(throws: CalendarDataError.self) { try store.runStore.finish(runID: run.id, status: .stopped) }
        #expect(store.runStore.run(id: run.id) == run)
        #expect(archive.records[run.id] == run)
        archive.failWrites = false
        let reopened = SourceRunStore(repository: archive)
        #expect(reopened.run(id: run.id)?.status == .interrupted)
        #expect(archive.records[run.id] == reopened.run(id: run.id))
    }

    @Test func legacyCollectionsImportBeforeRulesReplacementWithAnyRepository() throws {
        let source = LearnedReadingSource(name: "Inbox", meaning: "Incoming mail", url: "https://mail.example.test/inbox", scope: "Visible rows")
        let observation = snapshot(source)
        let rules = MemoryRulesRepository()
        rules.contents = LoadedSourceRules(rules: SourceRulesSnapshot(readingSources: [source]),
            legacyCollections: LegacySourceCollections(calendarSnapshots: [], readingSnapshots: [observation], removedSources: []))
        let archive = MemoryRunRepository()
        archive.failWrites = true
        let failed = CalendarStore(repository: rules, runStore: SourceRunStore(repository: archive))
        #expect(failed.error != nil)
        #expect(rules.contents?.legacyCollections != nil)
        archive.failWrites = false
        let imported = CalendarStore(repository: rules, runStore: SourceRunStore(repository: archive))
        #expect(imported.error == nil)
        #expect(imported.runStore.runs.count == 1)
        #expect(imported.runStore.runs.first?.origin == .migration)
        #expect(imported.readingSnapshots == [observation])
        #expect(rules.contents?.legacyCollections == nil)
    }

    private func snapshot(_ source: LearnedReadingSource) -> ReadingSnapshot {
        ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
            items: [ReadingItem(id: "mail-1", title: "Collected mail", text: "A visible message", evidence: "Visible row")],
            coverage: .complete, accountEvidence: "Current account", sourceEvidence: "Inbox", scopeEvidence: "Visible rows")
    }

    private final class MemoryRulesRepository: SourceRulesRepository {
        var contents: LoadedSourceRules?
        var failWrites = false
        func load() throws -> LoadedSourceRules? { contents }
        func save(_ rules: SourceRulesSnapshot) throws {
            if failWrites { throw CalendarDataError.unavailable("Rules are temporarily unavailable") }
            contents = LoadedSourceRules(rules: rules)
        }
    }

    private final class MemoryRunRepository: SourceRunRepository {
        var records: [UUID: SourceRunRecord] = [:]
        var failWrites = false
        var archiveDirectory: URL? { nil }
        func directory(for id: UUID) -> URL? { nil }
        func load() throws -> [SourceRunRecord] { Array(records.values) }
        func save(_ record: SourceRunRecord, replacing previous: SourceRunRecord?) throws {
            if failWrites { throw CalendarDataError.unavailable("History is temporarily unavailable") }
            try calendarRequire(records[record.id] == previous, "The saved run changed")
            records[record.id] = record
        }
    }
}
