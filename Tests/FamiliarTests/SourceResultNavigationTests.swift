import AppKit
import SwiftUI
import Testing
@testable import Familiar

@MainActor
struct SourceResultNavigationTests {
    @Test func completedSourceOpensItsResultInsteadOfSourceRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-result-navigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MorningStore(directory: directory.appendingPathComponent("morning"))
        let sources = CalendarStore(directory: directory.appendingPathComponent("sources"))
        let config = Config()
        let activities = NativeActivityGate()
        let registry = ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: config))
        let desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
        let runner = CalendarCollectionRunner(store: sources, desktop: desktop, registry: registry,
            activities: activities, config: { config })
        let navigation = MorningNavigation()
        let view = MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
            calendarSources: sources, calendarRunner: runner)
        let host = try #require(find(CalendarBatchHost.self, in: view.body))
        let runID = UUID(), sourceID = UUID()
        host.openRun(runID, sourceID)
        #expect(navigation.route == .sourceRun(runID: runID, sourceID: sourceID), "Opening a completed source must show its exact run result, not Manage sources and rules.")
        host.openHistory()
        #expect(navigation.route == .sourceRuns)
        host.openSources()
        #expect(navigation.route == .sources)
    }

    @Test func historicalRouteKeepsItsOwnFindingsAfterAnotherRunRemovalAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-history-navigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourcesDirectory = directory.appendingPathComponent("sources")
        let initial = CalendarStore(directory: sourcesDirectory)
        let source = LearnedReadingSource(kind: .mail, name: "Original inbox", meaning: "Work messages",
            url: "https://mail.example.test/inbox", account: "alex@example.test", scope: "The first page")
        try initial.saveReadingSource(source)
        func snapshot(_ title: String, at: Date) -> ReadingSnapshot {
            ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source, collectedAt: at,
                items: [ReadingItem(id: title, title: title, text: "Observed message", evidence: "Visible row")],
                coverage: .complete, accountEvidence: "Observed account", sourceEvidence: "Observed Inbox", scopeEvidence: "Observed first page")
        }
        try initial.saveReadingSnapshot(snapshot("Earlier finding", at: Date(timeIntervalSince1970: 1_800_000_000)))
        let earlierRun = try #require(initial.runStore.runs.first)
        try initial.saveReadingSnapshot(snapshot("Later finding", at: Date(timeIntervalSince1970: 1_800_000_060)))
        try initial.removeSource(id: source.id)
        let reopened = CalendarStore(directory: sourcesDirectory)
        #expect(reopened.readingSources.isEmpty)
        #expect(reopened.runStore.runs.count == 2)

        let config = Config(), activities = NativeActivityGate()
        let registry = ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: config))
        let runner = CalendarCollectionRunner(store: reopened,
            desktop: DesktopExecutionService(control: ComputerController(), activities: activities),
            registry: registry, activities: activities, config: { config })
        let navigation = MorningNavigation()
        navigation.route = .sourceRun(runID: earlierRun.id, sourceID: source.id)
        let files = MorningFilesView(store: MorningStore(directory: directory.appendingPathComponent("morning")),
            navigation: navigation, close: {}, filed: {}, handoff: { _ in }, calendarSources: reopened, calendarRunner: runner)
        let host = try #require(find(SourceRunResultsHost.self, in: files.body))
        let result = try #require(find(SourceRunResultsView.self, in: host.body))
        #expect(result.run.id == earlierRun.id)
        #expect(result.sourceID == source.id)
        #expect(result.run.entries.first?.readingSnapshot?.items.map(\.title) == ["Earlier finding"])
        #expect(!result.activeSourceIDs.contains(source.id))
    }

    /// Exercise the callback composed by the maintained SwiftUI screen, without GUI coordinates.
    private func find<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> T? {
        if let value = value as? T { return value }
        guard depth < 40 else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return nil }
        for child in mirror.children {
            if let result = find(type, in: child.value, depth: depth + 1) { return result }
        }
        return nil
    }
}
