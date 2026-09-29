import Foundation
import Combine
import ApplicationServices
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct CalendarCollectionRunnerTests {
    @Test func batchDoesNotOverwriteAnotherOwnersProgressBetweenSources() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.addSource("Waiting calendar", account: "later@example.test")
        var lease: NativeActivityGate.Lease?
        defer { if let lease { fixture.activities.release(lease) } }
        let observation = fixture.desktop.tasks.$history.sink { history in
            guard !history.isEmpty, lease == nil else { return }
            lease = try? fixture.activities.acquire(.recording)
            fixture.desktop.peek.caption = "Another owner's progress"
            fixture.desktop.peek.phase = .asking("Another task needs input")
        }
        defer { observation.cancel() }
        var calls = 0
        let runner = fixture.runner { _, _, _, executor in
            calls += 1
            _ = await executor("read_screen", [:], nil)
            _ = await executor("submit_calendar_collection", fixture.payload(), nil)
            return "Collected"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value
        #expect(lease != nil)
        #expect(calls == 1)
        #expect(runner.batchResults.map(\.state) == [.complete, .notRun])
        #expect(fixture.desktop.peek.caption == "Another owner's progress")
        #expect(fixture.desktop.peek.phase == .asking("Another task needs input"))
        #expect(!runner.isRunning)
    }

    @Test func runAllSourcesCollectsSeriallyWithFreshConversationsAndRejectsOverlappingStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let second = try fixture.addSource("Project calendar", account: "project@example.test")
        let third = try fixture.addSource("Personal calendar", account: "personal@example.test")
        let sources = [fixture.source, second, third]
        var calls: [UUID] = []
        var inFlight = 0
        var maximumInFlight = 0
        var runner: CalendarCollectionRunner!
        defer { runner = nil }
        runner = fixture.runner { _, _, messages, executor in
            let index = calls.count
            let source = sources[index]
            calls.append(source.id)
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            defer { inFlight -= 1 }
            #expect(runner.isRunning)
            #expect(runner.isBatchRunning)
            #expect(runner.activeSourceID == source.id)
            #expect(runner.batchResults[index].state == .reading)
            #expect(messages.count == 1)
            #expect(Self.messageText(messages).contains(source.id.uuidString))
            #expect(Self.messageText(messages).contains(source.account))
            for prior in sources.prefix(index) { #expect(fixture.store.latest(for: prior.id) != nil) }
            #expect(fixture.store.latest(for: source.id) == nil)
            await Task.yield()
            _ = await executor("read_screen", [:], nil)
            #expect(!(await executor("submit_calendar_collection", fixture.payload(for: source), nil)).isError)
            return "Read \(source.name)"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        #expect(runner.isRunning)
        #expect(runner.isBatchRunning)
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(runner.collect(source: fixture.source, day: fixture.day) == nil)
        await task.value

        #expect(calls == sources.map(\.id))
        #expect(maximumInFlight == 1)
        #expect(runner.batchResults.map(\.sourceID) == sources.map(\.id))
        #expect(runner.batchResults.map(\.sourceName) == sources.map(\.name))
        #expect(runner.batchResults.map(\.state) == [.complete, .complete, .complete])
        #expect(fixture.store.snapshots.count == 3)
        #expect(!runner.isRunning)
        #expect(!runner.isBatchRunning)
        #expect(runner.activeSourceID == nil)
    }

    @Test func runAllContinuesAfterProviderFailureAndInvalidSourceAndDistinguishesPartialCoverage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try fixture.seedSnapshot()
        let invalid = try fixture.addSource("Unconfirmed account", account: "")
        let partial = try fixture.addSource("Partly readable", account: "partial@example.test")
        let complete = try fixture.addSource("Fully readable", account: "complete@example.test")
        var calls: [UUID] = []
        let runner = fixture.runner { _, _, messages, executor in
            let text = Self.messageText(messages)
            #expect(!text.contains(invalid.id.uuidString))
            let source = try #require([fixture.source, partial, complete].first { text.contains($0.id.uuidString) })
            calls.append(source.id)
            if source.id == fixture.source.id {
                throw ClaudeError(message: "Calendar provider unavailable for first source")
            }
            _ = await executor("read_screen", [:], nil)
            let coverage: CalendarCoverage = source.id == partial.id ? .partial : .complete
            #expect(!(await executor("submit_calendar_collection", fixture.payload(for: source, coverage: coverage), nil)).isError)
            return "Read available records"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value

        #expect(calls == [fixture.source.id, partial.id, complete.id])
        #expect(runner.batchResults.map(\.state) == [.failed, .failed, .partial, .complete])
        #expect(runner.batchResults[0].message.contains("provider unavailable"))
        #expect(runner.batchResults[1].message.localizedCaseInsensitiveContains("account"))
        #expect(fixture.store.latest(for: fixture.source.id) == previous)
        #expect(fixture.store.latest(for: invalid.id) == nil)
        let collectedPartial = try #require(fixture.store.latest(for: partial.id))
        #expect(collectedPartial.coverage == .partial)
        #expect(collectedPartial.coverageNotes == ["The afternoon could not be read"])
        #expect(fixture.store.latest(for: complete.id)?.coverage == .complete)
        #expect(!runner.isRunning)
        let reopened = CalendarStore(directory: fixture.directory)
        let runID = try #require(runner.currentRunID)
        let run = try #require(reopened.runStore.run(id: runID))
        #expect(run.origin == .all)
        #expect(run.status == .failed)
        #expect(run.entries.map(\.state) == [.failed, .failed, .partial, .complete])
        #expect(run.entries.map(\.sourceID) == [fixture.source.id, invalid.id, partial.id, complete.id])
        #expect(run.entries[0].calendarSnapshot == nil)
        #expect(run.entries[1].calendarSnapshot == nil)
        #expect(run.entries[2].calendarSnapshot == collectedPartial)
        #expect(run.entries[3].calendarSnapshot?.source == complete)
    }

    @Test func stoppingBatchKeepsCompletedSourceDiscardsActiveStagingAndNeverStartsRemainingSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let second = try fixture.addSource("Reading when stopped", account: "second@example.test")
        let third = try fixture.addSource("Must not run", account: "third@example.test")
        var calls: [UUID] = []
        var secondEntered = false
        var originalStops = 0
        fixture.desktop.peek.onStop = { originalStops += 1 }
        let runner = fixture.runner { _, _, messages, executor in
            let text = Self.messageText(messages)
            let source = try #require([fixture.source, second, third].first { text.contains($0.id.uuidString) })
            calls.append(source.id)
            _ = await executor("read_screen", [:], nil)
            #expect(!(await executor("submit_calendar_collection", fixture.payload(for: source), nil)).isError)
            if source.id == second.id {
                secondEntered = true
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return "Read \(source.name)"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        try await until { secondEntered }
        #expect(runner.isRunning)
        #expect(runner.isBatchRunning)
        let completed = try #require(fixture.store.latest(for: fixture.source.id))
        runner.backgroundDidBegin()
        fixture.desktop.peek.onStop?()
        await task.value

        #expect(calls == [fixture.source.id, second.id])
        #expect(runner.batchResults.map(\.state) == [.complete, .stopped, .notRun])
        #expect(fixture.store.latest(for: fixture.source.id) == completed)
        #expect(fixture.store.latest(for: second.id) == nil)
        #expect(fixture.store.latest(for: third.id) == nil)
        #expect(!runner.isRunning)
        #expect(!runner.isBatchRunning)
        #expect(runner.activeSourceID == nil)
        #expect(fixture.desktop.tasks.activeTask == nil)
        fixture.desktop.peek.onStop?()
        #expect(originalStops == 1)
    }

    @Test func batchFreezesSourceProfilesAndUsesEachSourcesLocalDate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let second = try fixture.addSource("Tokyo calendar", account: "original@example.test", timeZoneID: "Asia/Tokyo")
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-28T02:00:00Z"))
        var calls: [UUID] = []
        let runner = fixture.runner { _, _, messages, executor in
            let text = Self.messageText(messages)
            let source = try #require([fixture.source, second].first { text.contains($0.id.uuidString) })
            calls.append(source.id)
            if source.id == fixture.source.id {
                #expect(text.contains("2026-09-27"))
                var edited = second
                edited.account = "edited-after-batch-start@example.test"
                try fixture.store.saveSource(edited)
                _ = try fixture.addSource("Added after batch started", account: "new@example.test")
            } else {
                #expect(text.contains("2026-09-28"))
                #expect(text.contains("Asia/Tokyo"))
                #expect(text.contains("original@example.test"))
                #expect(!text.contains("edited-after-batch-start@example.test"))
            }
            _ = await executor("read_screen", [:], nil)
            #expect(!(await executor("submit_calendar_collection", fixture.payload(for: source, day: instant), nil)).isError)
            return "Read \(source.name)"
        }
        let task = try #require(runner.collectAll(day: instant, startHour: 8, endHour: 18))
        await task.value

        #expect(calls == [fixture.source.id, second.id])
        #expect(runner.batchResults.map(\.dateLabel) == ["2026-09-27", "2026-09-28"])
        #expect(runner.batchResults.map(\.state) == [.complete, .complete])
        #expect(fixture.store.snapshots.count == 2)
        #expect(fixture.store.snapshots.allSatisfy { $0.startHour == 8 && $0.endHour == 18 })
        #expect(fixture.store.snapshots.first { $0.sourceID == second.id }?.source == second)
        #expect(fixture.store.latest(for: second.id) == nil)
    }

    @Test func batchPreflightRejectsEmptySourcesBusyDesktopAndUnavailableConfiguration() throws {
        let fixture = try Fixture(saveInitialSource: false)
        defer { fixture.remove() }
        var factories = 0
        var settings = Config()
        settings.allowControl = true
        let runner = CalendarCollectionRunner(store: fixture.store, desktop: fixture.desktop,
            registry: fixture.registry, activities: fixture.activities, config: { settings },
            makeClient: { _ in factories += 1; return nil })
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(runner.error != nil)
        #expect(factories == 0)
        #expect(runner.batchResults.isEmpty)
        var unconfirmed = fixture.source
        unconfirmed.account = ""
        try fixture.store.saveSource(unconfirmed)
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(runner.batchResults.map(\.state) == [.failed])
        #expect(factories == 0)
        try fixture.store.saveSource(fixture.source)
        #expect(runner.collectAll(day: Date(timeIntervalSince1970: .infinity)) == nil)
        #expect(runner.batchResults.map(\.state) == [.failed])
        #expect(runner.batchResults.first?.dateLabel == "Invalid day")
        #expect(factories == 0)
        let lease = try fixture.activities.acquire(.recording)
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(runner.batchResults.map(\.state) == [.notRun])
        fixture.activities.release(lease)
        #expect(factories == 0)
        let otherTaskID = UUID()
        fixture.desktop.tasks.start(id: otherTaskID, title: "Another desktop task")
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(factories == 0)
        fixture.desktop.tasks.finish(id: otherTaskID, outcome: .completed, text: "Done", elapsed: 0)
        settings.allowControl = false
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(factories == 0)
        settings.allowControl = true
        #expect(runner.collectAll(day: fixture.day) == nil)
        #expect(factories == 1)
        #expect(runner.batchResults.map(\.state) == [.notRun])
        #expect(!runner.isRunning)
        #expect(!runner.isBatchRunning)
        #expect(fixture.desktop.tasks.activeTask == nil)
        #expect(fixture.store.snapshots.isEmpty)
    }

    @Test func learnedMeaningCollectsAnotherDayThroughFreshToolsAndIgnoresFinalProse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = fixture.runner { system, tools, messages, executor in
            #expect(system.contains("not a click script"))
            #expect(system.contains("No target window is selected"))
            let text = Self.messageText(messages)
            #expect(text.contains("2026-09-28"))
            #expect(text.contains("My meeting schedule means the work calendar"))
            #expect(text.contains("2026-09-01"))
            #expect(tools.contains { $0["name"] as? String == "submit_calendar_collection" })
            let premature = await executor("submit_calendar_collection", fixture.payload(), nil)
            #expect(premature.isError)
            _ = await executor("read_screen", [:], nil)
            let saved = await executor("submit_calendar_collection", fixture.payload(), nil)
            #expect(!saved.isError)
            #expect(fixture.store.snapshots.isEmpty)
            return "I moved your meeting and booked lunch. This final prose must not become the briefing."
        }
        let task = try #require(runner.collect(source: fixture.source, day: fixture.day))
        await task.value

        let snapshot = try #require(fixture.store.latest(for: fixture.source.id))
        #expect(snapshot.dateLabel == "2026-09-28")
        #expect(snapshot.events.map(\.title) == ["Current-day review"])
        #expect(runner.error == nil)
        #expect(!runner.isRunning)
        let result = try #require(fixture.desktop.tasks.history.first)
        #expect(result.outcome == .completed)
        #expect(!result.text.contains("booked lunch"))
        #expect(result.text == CalendarBriefing.render(snapshot))
    }

    @Test func proseAndObservationWithoutStructuredSubmissionDoNotOverwriteSavedData() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try fixture.seedSnapshot()
        let runner = fixture.runner { _, _, _, executor in
            _ = await executor("read_screen", [:], nil)
            return "Everything is clear until noon."
        }
        let task = try #require(runner.collect(source: fixture.source, day: fixture.day))
        await task.value

        #expect(fixture.store.snapshots == [previous])
        #expect(runner.error?.contains("saved nothing new") == true)
        #expect(fixture.desktop.tasks.history.first?.outcome == .failed)
    }

    @Test func navigationInvalidatesStagedDataUntilAnotherReadAndSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = fixture.runner { _, _, _, executor in
            _ = await executor("read_screen", [:], nil)
            #expect(!(await executor("submit_calendar_collection", fixture.payload(), nil)).isError)
            _ = await executor("target_window", ["select": 2], nil)
            #expect((await executor("submit_calendar_collection", fixture.payload(), nil)).isError)
            return "Done"
        }
        let task = try #require(runner.collect(source: fixture.source, day: fixture.day))
        await task.value
        #expect(fixture.store.snapshots.isEmpty)
        #expect(runner.error != nil)

        let next = fixture.runner { _, _, _, executor in
            _ = await executor("read_screen", [:], nil)
            _ = await executor("target_window", ["select": 2], nil)
            _ = await executor("read_screen", [:], nil)
            #expect(!(await executor("submit_calendar_collection", fixture.payload(), nil)).isError)
            return "Collected"
        }
        let retry = try #require(next.collect(source: fixture.source, day: fixture.day))
        await retry.value
        #expect(fixture.store.snapshots.count == 1)
    }

    @Test func rejectedReplacementCannotLeaveAnOlderSubmissionStaged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let evidence = CalendarCollectionEvidence()
        evidence.observed()
        try evidence.submit(fixture.payload(), request: fixture.request)
        #expect(evidence.snapshot != nil)
        var changed = fixture.payload()
        changed["day"] = "2026-09-29"
        #expect(throws: (any Error).self) { try evidence.submit(changed, request: fixture.request) }
        #expect(evidence.snapshot == nil)
    }

    @Test func providerFailureAfterSubmissionDoesNotCommitAndCancellationRestoresStop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failing = fixture.runner { _, _, _, executor in
            _ = await executor("read_screen", [:], nil)
            _ = await executor("submit_calendar_collection", fixture.payload(), nil)
            throw ClaudeError(message: "Connection lost after staging")
        }
        let failed = try #require(failing.collect(source: fixture.source, day: fixture.day))
        await failed.value
        #expect(fixture.store.snapshots.isEmpty)
        #expect(failing.error?.contains("Connection lost") == true)

        var entered = false
        var originalStops = 0
        fixture.desktop.peek.onStop = { originalStops += 1 }
        let cancellable = fixture.runner { _, _, _, executor in
            _ = await executor("read_screen", [:], nil)
            _ = await executor("submit_calendar_collection", fixture.payload(), nil)
            entered = true
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "Too late"
        }
        let task = try #require(cancellable.collect(source: fixture.source, day: fixture.day))
        try await until { entered }
        cancellable.backgroundDidBegin()
        fixture.desktop.peek.onStop?()
        await task.value
        #expect(fixture.store.snapshots.isEmpty)
        #expect(!cancellable.isRunning)
        #expect(fixture.desktop.tasks.history.first?.outcome == .stopped)
        fixture.desktop.peek.onStop?()
        #expect(originalStops == 1)
    }

    @Test func persistenceFailureIsNeverPresentedAsSuccessfulCollection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try fixture.seedSnapshot()
        let runner = fixture.runner { _, _, _, executor in
            _ = await executor("read_screen", [:], nil)
            _ = await executor("submit_calendar_collection", fixture.payload(), nil)
            try fixture.blockWrites()
            return "Finished"
        }
        let task = try #require(runner.collect(source: fixture.source, day: fixture.day))
        await task.value
        #expect(fixture.store.snapshots == [previous])
        #expect(runner.error?.contains("could not be saved") == true)
        #expect(fixture.desktop.tasks.history.first?.outcome == .failed)
    }

    @Test func busyNativeOwnerAndDisabledControlDoNotConsumeProvider() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var factories = 0
        var settings = Config()
        let runner = CalendarCollectionRunner(store: fixture.store, desktop: fixture.desktop,
            registry: fixture.registry, activities: fixture.activities, config: { settings },
            makeClient: { _ in factories += 1; return FakeClient { _, _, _, _ in "unused" } })
        #expect(runner.collect(source: fixture.source, day: fixture.day) == nil)
        #expect(runner.error?.contains("computer control") == true)
        settings.allowControl = true
        let lease = try fixture.activities.acquire(.recording)
        #expect(runner.collect(source: fixture.source, day: fixture.day) == nil)
        #expect(runner.error?.contains("Watch Me") == true)
        fixture.activities.release(lease)
        #expect(factories == 0)
        #expect(!runner.isRunning)
    }

    @Test func nativePreparationHasNoImplicitTargetOrMutationRoutesAndReleasesOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var settings = Config()
        settings.allowControl = true
        let runner = CalendarCollectionRunner(store: fixture.store, desktop: fixture.desktop,
            registry: fixture.registry, activities: fixture.activities, config: { settings },
            makeClient: { _ in FakeClient { _, tools, _, executor in
                #expect(fixture.desktop.control.target == nil)
                #expect(fixture.desktop.control.pressRefusal != nil)
                #expect(fixture.activities.current?.activity == .desktop)
                let names = Set(tools.compactMap { $0["name"] as? String })
                #expect(names == ["target_window", "read_screen", "look_at_screen", "find_on_screen", "click_element", "calendar_scroll", "submit_calendar_collection"])
                #expect(!tools.contains { $0["type"] as? String == "computer_toolset_20260801" })
                for name in ["send_message", "type", "key", "left_click", "ask_for_the_mouse", "read_file"] {
                    #expect((await executor(name, [:], nil)).isError)
                    #expect((await executor(name, [:], "computer")).isError)
                }
                #expect((await executor("read_screen", [:], nil)).isError)
                #expect((await executor("submit_calendar_collection", fixture.payload(), nil)).isError)
                return "No target available"
            } })
        let task = try #require(runner.collect(source: fixture.source, day: fixture.day))
        await task.value
        #expect(!fixture.desktop.isBusy)
        #expect(fixture.activities.current == nil)
        #expect(fixture.desktop.control.pressRefusal == nil)
        #expect(fixture.store.snapshots.isEmpty)
    }

    @Test func liveControlPolicyRefusesEditingAndUnknownControls() {
        for title in ["Accept", "Decline", "Edit calendar", "New event", "Save", "Delete", "Reschedule", "Join", "Share calendar", "Calendar settings", "Unrecognized control"] {
            #expect(CalendarNavigationPolicy.refusal(.init(role: "AXButton", title: title)) != nil)
        }
        for title in ["Today", "Next day", "Previous week", "September 28, 2026", "Day", "Work week"] {
            #expect(CalendarNavigationPolicy.refusal(.init(role: "AXButton", title: title)) == nil)
        }
        #expect(CalendarNavigationPolicy.refusal(.init(role: "AXCell", title: "Product review")) == nil)
        #expect(CalendarNavigationPolicy.refusal(.init(role: "AXButton", title: "Next day", domID: "calendar-navigation-next-button")) == nil)
        #expect(CalendarNavigationPolicy.refusal(.init(role: "AXButton", title: "Calendar", description: "Edit calendar")) != nil)
        #expect(CalendarNavigationPolicy.refusal(.init(role: "AXTextField", title: "Calendar")) != nil)
        #expect(CalendarNavigationPolicy.refusal(.init(role: "AXButton", subrole: "AXCloseButton", title: "Close")) != nil)
        #expect(CalendarNavigationPolicy.refusal(.init(role: "AXButton", title: "Day", isDefaultButton: true)) != nil)
    }

    @Test func actualPressRechecksLiveMetadataAfterSuspendingForCapture() async {
        let element = AXUIElementCreateApplication(-23456)
        let target = TargetWindow(pid: -23456, bundleID: "test.calendar", appName: "Fixture", cgWindowID: 0,
            axApp: element, axWindow: element, toolkit: .appKit, backingScale: 1, scWindow: nil,
            frameCG: CGRect(x: 0, y: 0, width: 640, height: 480), title: "Fixture")
        let ladder = ActionLadder(target: target, maxLongEdge: 640)
        ladder.pressRefusal = CalendarNavigationPolicy.refusal
        var label = "Save calendar"
        var captures = 0
        var presses = 0
        ladder.readPressInfo = { _ in .init(role: "AXButton", title: label) }
        ladder.capturePressState = { _ in
            captures += 1
            label = "Delete calendar"
            await Task.yield()
            return AXSnapshot()
        }
        ladder.performPress = { _ in presses += 1 }
        #expect((await ladder.pressElement(element)).isError)
        #expect(captures == 0)
        #expect(presses == 0)
        label = "Next day"
        #expect((await ladder.pressElement(element)).isError)
        #expect(captures == 1)
        #expect(presses == 0)
    }

    private func until(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(condition())
    }

    private static func messageText(_ messages: [[String: Any]]) -> String {
        ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-runner-\(UUID().uuidString)")
        let activities = NativeActivityGate()
        let source = LearnedCalendarSource(name: "Work meetings", meaning: "My meeting schedule means the work calendar",
            application: "Outlook", bundleID: "com.microsoft.Outlook", account: "me@example.test", calendarName: "Calendar",
            timeZoneID: "America/New_York", navigationHints: "Use the calendar date heading and Day view",
            completionChecks: "Check all-day events and every hour", learnedAt: ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")!)
        let day = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        lazy var store = CalendarStore(directory: directory)
        lazy var desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
        lazy var registry = ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: Config()))

        init(saveInitialSource: Bool = true) throws {
            if saveInitialSource { try store.saveSource(source) }
        }

        var request: CalendarReadRequest { CalendarReadRequest(source: source, day: day) }

        func addSource(_ name: String, account: String, timeZoneID: String = "America/New_York") throws -> LearnedCalendarSource {
            var extra = source
            extra.id = UUID()
            extra.name = name
            extra.account = account
            extra.timeZoneID = timeZoneID
            try store.saveSource(extra)
            return extra
        }

        func payload(for source: LearnedCalendarSource? = nil, day: Date? = nil, coverage: CalendarCoverage = .complete) -> [String: Any] {
            let source = source ?? self.source
            let request = CalendarReadRequest(source: source, day: day ?? self.day)
            let start = request.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: request.day)!
            let end = request.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: request.day)!
            let format = ISO8601DateFormatter()
            return ["sourceID": source.id.uuidString, "day": request.dateLabel, "timeZoneID": source.timeZoneID,
             "coverage": coverage.rawValue, "coverageNotes": coverage == .partial ? ["The afternoon could not be read"] : ["All hours and the all-day area inspected"],
             "accountEvidence": "Account menu: \(source.account)", "calendarEvidence": "Calendar selected under work account",
             "dateEvidence": "Heading \(request.dateLabel), time zone \(source.timeZoneID)",
             "events": [["title": "Current-day review", "start": format.string(from: start), "end": format.string(from: end),
                         "allDay": false, "response": "accepted", "availability": "busy", "isCancelled": false,
                         "evidence": "Current-day review · 9:00–10:00 · Accepted · Busy"]]]
        }

        func seedSnapshot() throws -> CalendarSnapshot {
            let snapshot = try CalendarSubmission.parse(payload(), request: request)
            try store.saveSnapshot(snapshot)
            return try #require(store.latest(for: source.id))
        }

        func runner(_ body: @escaping FakeClient.Body) -> CalendarCollectionRunner {
            var settings = Config()
            settings.allowControl = true
            return CalendarCollectionRunner(store: store, desktop: desktop, registry: registry, activities: activities,
                config: { settings }, makeClient: { _ in FakeClient(body) },
                prepareExecution: { _, additional, evidence in
                    let read = ToolRoute(match: .tool(name: "read_screen"), definition: ["name": "read_screen"]) { _, _, _ in
                        evidence.observed()
                        return .text("Fresh calendar fixture")
                    }
                    let navigate = ToolRoute(match: .tool(name: "target_window"), definition: ["name": "target_window"]) { _, _, _ in
                        evidence.navigated()
                        return .text("Changed calendar window")
                    }
                    return PreparedExecution(system: "fixture", router: try ToolRouter(routes: additional + [read, navigate]))
                })
        }

        func blockWrites() throws {
            let archive = try #require(store.runStore.archiveDirectory)
            try FileManager.default.moveItem(at: archive, to: directory.appendingPathComponent("previous-runs"))
            try Data("Archive storage is unavailable".utf8).write(to: archive)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class FakeClient: ConversationClient {
        typealias Body = @MainActor (String, [[String: Any]], [[String: Any]], @escaping ToolExecutor) async throws -> String
        var effort = "medium"
        var maxTokens = 1024
        var maxToolRounds = 8
        var shouldStop: () -> Bool = { false }
        let body: Body
        init(_ body: @escaping Body) { self.body = body }
        func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                      executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
            let text = try await body(system, tools, messages, executor)
            messages.append(["role": "assistant", "content": [["type": "text", "text": text]]])
            return ClaudeReply(text: text, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 0)
        }
    }
}
