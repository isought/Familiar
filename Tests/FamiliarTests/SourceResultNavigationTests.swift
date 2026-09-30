import AppKit
import SwiftUI
import Testing
import FamiliarContracts
@testable import Familiar

@MainActor
struct SourceResultNavigationTests {
    @Test func mainScreenOpensTheLatestRunAndBackReturnsToIt() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let view = fixture.files()
        let host = try #require(find(CalendarBatchHost.self, in: view.body))
        host.openLatest()
        #expect(fixture.navigation.route == .latestRun, "The latest run opens its results, not Manage sources and rules.")
        view.back()
        #expect(fixture.navigation.route == .folders)
        host.openHistory()
        #expect(fixture.navigation.route == .sourceRuns)
        host.openSources()
        #expect(fixture.navigation.route == .sources)
    }

    @Test func readingYourSourcesFromTheMainScreenOpensTheLatestRun() async throws {
        let fixture = Fixture(savingSource: false)
        defer { fixture.remove() }
        let job = LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My inbox", application: "Mail",
                                       scope: "Skip promotions", script: "mail__today")
        try fixture.sources.saveReadingSource(job)
        fixture.runner.readScript = { _ in
            ["mailbox": "INBOX", "arrived": 1, "items": [["key": "a@example.test", "title": "Invoice due Friday"]]] as [String: Any]
        }
        let view = fixture.files()
        let host = try #require(find(CalendarBatchHost.self, in: view.body))
        let controls = try #require(find(CalendarBatchControls.self, in: host.body))
        controls.runAll()
        #expect(fixture.navigation.route == .latestRun)
        let deadline = Date().addingTimeInterval(10)
        while fixture.runner.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let run = try #require(fixture.sources.runStore.runs.first)
        #expect(run.id == fixture.runner.currentRunID)
        #expect(run.entries.map(\.state) == [.complete])
        view.back()
        #expect(fixture.navigation.route == .folders, "Back from a read started on the main screen returns there, not to Run history.")
    }

    @Test func latestRunShowsTheNewestRunInFullAndFollowsANewOne() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.navigation.route = .latestRun
        func shown() throws -> SourceRunResultsHost? {
            let latest = try #require(find(LatestRunHost.self, in: fixture.files().body))
            return find(SourceRunResultsHost.self, in: latest.body)
        }
        #expect(try shown() == nil, "With no runs the screen says so instead of showing a run.")
        _ = try fixture.run([.failed], at: Date(timeIntervalSince1970: 1_800_000_000))
        let newest = try fixture.run([.complete, .failed], at: Date(timeIntervalSince1970: 1_800_000_060))
        #expect(try shown()?.runID == newest.id)
        #expect(try shown()?.sourceID == nil, "The latest run shows every source, not one.")
        let started = try fixture.sources.runStore.begin(entries: [fixture.entry(.waiting)], origin: .all,
                                                        startedAt: Date(timeIntervalSince1970: 1_800_000_120))
        #expect(try shown()?.runID == started.id, "A run that starts while the screen is open takes its place.")
    }

    @Test func latestRunLinkSaysWhenSourcesDidNotFinish() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        func run(_ states: [SourceRunEntry.State], status: SourceRunStatus = .completed) -> SourceRunRecord {
            SourceRunRecord(origin: .all, startedAt: Date(), finishedAt: Date(), timeZoneID: "UTC", status: status,
                            entries: states.map { fixture.entry($0) })
        }
        #expect(LatestRunNote(run: run([.complete, .complete])) == nil, "A clean run needs no note.")
        let one = try #require(LatestRunNote(run: run([.complete, .failed])))
        #expect(one.text == "1 source didn’t finish")
        #expect(one.isProblem)
        let several = try #require(LatestRunNote(run: run([.partial, .stopped, .notRun, .interrupted, .complete])))
        #expect(several.text == "4 sources didn’t finish")
        let reading = try #require(LatestRunNote(run: run([.complete, .reading], status: .running)))
        #expect(reading.text == "reading now")
        #expect(!reading.isProblem)
    }

    @Test func cardControlsLiveWithTheRunsAndTheMainScreenShowsOnlyWorkOrFailure() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        _ = try fixture.run([.complete], at: Date())
        let cards = CardGenerationService(morning: fixture.morning, sources: fixture.sources, desktop: fixture.desktop,
                                          config: { Config() }, makeClient: { _ in nil })
        let view = fixture.files(cardGeneration: cards)
        #expect(find(CardGenerationControls.self, in: view.body) == nil, "The main screen has no card controls of its own.")
        let line = try #require(find(CardGenerationStatusLine.self, in: view.body))
        #expect(find(Text.self, in: line.body) == nil, "Nothing shows on the main screen while cards are idle.")
        await cards.generate()?.value
        #expect(cards.error != nil)
        #expect(find(Text.self, in: line.body) != nil, "A card failure shows on the main screen.")
        line.openDetails()
        #expect(fixture.navigation.route == .latestRun)
        for route: MorningNavigation.Route in [.latestRun, .sourceRuns, .sourceRun(runID: UUID(), sourceID: nil)] {
            fixture.navigation.route = route
            #expect(find(CardGenerationControls.self, in: view.body) != nil, "Card controls show on \(route).")
            #expect(find(CardGenerationStatusLine.self, in: view.body) == nil)
        }
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

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("latest-run-\(UUID())")
        let navigation = MorningNavigation()
        let source = LearnedReadingSource(kind: .mail, name: "Inbox", meaning: "Unread mail",
                                          url: "https://mail.example.test/inbox", scope: "Recent unread messages")
        let morning: MorningStore
        let sources: CalendarStore
        let desktop: DesktopExecutionService
        let runner: CalendarCollectionRunner

        init(savingSource: Bool = true) {
            morning = MorningStore(directory: directory.appendingPathComponent("morning"))
            sources = CalendarStore(directory: directory.appendingPathComponent("sources"))
            var config = Config()
            config.allowControl = false
            let activities = NativeActivityGate()
            desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
            runner = CalendarCollectionRunner(store: sources, desktop: desktop,
                registry: ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: config)),
                activities: activities, config: { config }, makeClient: { _ in UnusedClient() })
            if savingSource { try? sources.saveReadingSource(source) }
        }

        func files(cardGeneration: CardGenerationService? = nil) -> MorningFilesView {
            MorningFilesView(store: morning, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
                             calendarSources: sources, calendarRunner: runner, cardGeneration: cardGeneration)
        }

        /// One source's entry in a run; a complete one carries the finding it read. Each entry is its own source.
        func entry(_ state: SourceRunEntry.State) -> SourceRunEntry {
            var read = source
            if state != .complete { read.id = UUID() }
            let request = ReadingReadRequest(source: read)
            var entry = SourceRunEntry(reading: request, state: state)
            if state == .complete {
                entry.readingSnapshot = ReadingSnapshot(requestID: request.id, sourceID: read.id, source: read,
                    items: [ReadingItem(id: "row-1", title: "Contract review", text: "Review the contract by Friday",
                                        evidence: "Visible message row")],
                    coverage: .complete, accountEvidence: "Current account", sourceEvidence: "Inbox", scopeEvidence: "Recent unread messages")
            }
            return entry
        }

        @discardableResult
        func run(_ states: [SourceRunEntry.State], at: Date) throws -> SourceRunRecord {
            let run = try sources.runStore.begin(entries: states.map(entry), origin: .all, startedAt: at)
            return try sources.runStore.finish(runID: run.id, status: .completed, finishedAt: at.addingTimeInterval(60))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A script job reads without the model, but a read still needs one connected.
    private final class UnusedClient: ConversationClient {
        var effort = "medium"
        var maxTokens = 1_024
        var maxToolRounds = 1
        var shouldStop: () -> Bool = { false }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            Issue.record("A script job read asked the model.")
            return ClaudeReply(text: "", inputTokens: 0, outputTokens: 0, cacheRead: 0, toolCalls: 0)
        }
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
