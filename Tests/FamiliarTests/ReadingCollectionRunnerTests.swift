import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct ReadingCollectionRunnerTests {
    @Test func taughtGmailSourceKeptFromWatchMeIsCollectedByRunAll() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let recordingDirectory = fixture.directory.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        let source = fixture.mail
        let recording = Recording(dir: recordingDirectory,
            events: [WatchEvent(index: 0, t: 0, kind: "scene", app: "Google Chrome", title: "Inbox - Gmail", url: source.url),
                     WatchEvent(index: 1, t: 1, kind: "click", app: "Google Chrome", title: "Inbox - Gmail", url: source.url, label: "Primary")],
            meta: WatchMeta(startedAt: "2026-09-28", hosts: ["mail.google.com"], titles: ["Inbox - Gmail"],
                            apps: ["Google Chrome"], bundles: ["com.google.Chrome"]))
        let json: [String: Any] = [
            "pack_dir": "gmail", "pack_name": "Gmail", "match_titles": ["Gmail"],
            "workflow_slug": "check-inbox", "workflow_title": "Check the Gmail inbox",
            "workflow_markdown": "Read Primary. Teaching example subject: OLD DEMONSTRATED EMAIL.",
            "reading_source": ["kind": "mail", "name": source.name, "meaning": source.meaning,
                "application": source.application, "bundle_id": source.bundleID, "url": source.url,
                "account": source.account, "scope": source.scope, "navigation_hints": source.navigationHints,
                "completion_checks": source.completionChecks, "uncertainties": []]
        ]
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        let learning = WatchLearnSession(operations: .init(start: { _ in }, stop: { recording }, abandon: {},
            summarize: { actual, _, _ in WatchSummarizer.parse(reply, recording: actual) },
            write: { try PackWriter.write($0, root: fixture.registry.root) }, reload: {},
            saveSource: { draft in try fixture.store.saveReadingSource(try #require(draft.readingSource)) }, saveMeta: { _ in }))
        #expect(try learning.start(source: true))
        let stopped = try #require(learning.stop())
        await stopped.value
        let summarized = try #require(learning.summarize(purpose: "This Gmail Primary inbox is my incoming work mail"))
        await summarized.value
        #expect(learning.phase == .review)
        #expect(learning.pendingDraft?.readingSource != nil)
        #expect(fixture.store.readingSources.isEmpty)
        await learning.keep()
        #expect(learning.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: recordingDirectory.path))
        let kept = try #require(fixture.store.readingSources.first)
        #expect(fixture.store.sources.isEmpty)
        var providerCalls = 0
        let runner = fixture.runner { system, tools, messages, executor in
            providerCalls += 1
            #expect(system.contains("not an action script"))
            #expect(system.contains("Do not open mail rows"))
            #expect(!Self.text(messages).contains("OLD DEMONSTRATED EMAIL"))
            #expect(Self.text(messages).contains(kept.meaning))
            #expect(tools.contains { $0["name"] as? String == "submit_reading_collection" })
            #expect(!tools.contains { $0["name"] as? String == "submit_calendar_collection" })
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.payload(source: kept, messages: messages)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            #expect(fixture.store.readingSnapshots.isEmpty)
            return "Finished"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value
        #expect(providerCalls == 1)
        #expect(runner.batchResults.map(\.sourceID) == [kept.id])
        #expect(runner.batchResults.map(\.state) == [.complete])
        let snapshot = try #require(fixture.store.latestReading(for: kept.id))
        #expect(snapshot.items.map(\.title) == ["Fresh incoming message"])
        #expect(snapshot.source == kept)
        #expect(fixture.store.snapshots.isEmpty)
    }

    @Test func mixedBatchRoutesCalendarAndMailThroughSeparateFreshStructuredSubmissions() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveSource(fixture.calendar)
        try fixture.store.saveReadingSource(fixture.mail)
        var calls: [String] = []
        let runner = fixture.runner { _, tools, messages, executor in
            #expect(messages.count == 1)
            let names = Set(tools.compactMap { $0["name"] as? String })
            _ = await executor("read_screen", [:], nil)
            if names.contains("submit_calendar_collection") {
                #expect(!names.contains("submit_reading_collection"))
                calls.append("calendar")
                #expect((await executor("submit_reading_collection", [:], nil)).isError)
                #expect(!(await executor("submit_calendar_collection", fixture.calendarPayload(), nil)).isError)
            } else {
                #expect(fixture.store.latest(for: fixture.calendar.id) != nil)
                calls.append("mail")
                #expect(names.contains("submit_reading_collection"))
                #expect((await executor("submit_calendar_collection", [:], nil)).isError)
                let payload = try fixture.payload(messages: messages)
                #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            }
            return "Observed"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value
        #expect(calls == ["calendar", "mail"])
        #expect(runner.batchResults.map(\.sourceID) == [fixture.calendar.id, fixture.mail.id])
        #expect(runner.batchResults.map(\.state) == [.complete, .complete])
        #expect(fixture.store.snapshots.count == 1)
        #expect(fixture.store.readingSnapshots.count == 1)
        #expect(!runner.isRunning)
        let run = try #require(fixture.store.runStore.runs.first)
        #expect(run.id == runner.currentRunID)
        #expect(run.origin == .all)
        #expect(run.status == .completed)
        #expect(run.entries.count == 2)
        #expect(run.entries[0].calendarSnapshot?.source == fixture.calendar)
        #expect(run.entries[1].readingSnapshot?.source == fixture.mail)
    }

    /// The bug: a failed read only said "No fresh, validated source collection was submitted…", dropping the
    /// reader's own explanation and the reason its findings were turned down.
    @Test func aReadThatSavesNothingSaysWhyAndWhatToSetUp() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        let runner = fixture.runner { _, _, messages, executor in
            _ = await executor("read_screen", [:], nil)
            var payload = try fixture.payload(messages: messages)
            payload["requestID"] = UUID().uuidString
            #expect((await executor("submit_reading_collection", payload, nil)).isError)
            return "The page shows a Google sign-in screen, so I could not read the inbox."
        }
        let task = try #require(runner.collect(source: fixture.mail, requestedAt: fixture.day))
        await task.value

        let message = try #require(runner.error)
        #expect(message.contains("saved nothing new"))
        #expect(message.contains("It said: “The page shows a Google sign-in screen, so I could not read the inbox.”"))
        #expect(message.contains("turned down"))
        #expect(message.contains("Google Chrome"))
        #expect(message.contains(fixture.mail.url))
        #expect(message.contains(fixture.mail.account))
        #expect(message.contains("It opens that address itself when no tab shows it, but can't sign in, switch accounts or use menus"))
        #expect(fixture.store.runStore.runs.last?.entries.first?.message == message)
    }

    @Test func aRunTellsItsStoryInTheLog() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        var lines: [String] = []
        let failing = fixture.runner { _, _, _, _ in "The page shows a Google sign-in screen." }
        failing.log = { lines.append($0) }
        await (try #require(failing.collect(source: fixture.mail, requestedAt: fixture.day))).value
        #expect(lines.first == "run started: 1 source (single)")
        #expect(lines.contains { $0.hasPrefix("run: “Gmail inbox” failed") && $0.contains("sign-in screen") })
        #expect(lines.last?.hasPrefix("run finished with problems: saved to ") == true)

        lines = []
        let working = fixture.runner { _, _, messages, executor in
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.payload(messages: messages)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            return "Finished"
        }
        working.log = { lines.append($0) }
        await (try #require(working.collect(source: fixture.mail, requestedAt: fixture.day))).value
        #expect(lines.contains { $0.hasPrefix("run: “Gmail inbox” complete") })
        #expect(lines.last?.hasPrefix("run completed: saved to ") == true)
    }

    @Test func aCalendarChecklistNamesTheCalendarToShow() {
        let source = LearnedCalendarSource(name: "Work", meaning: "My meetings", application: "Calendar", bundleID: "com.apple.iCal",
                                           account: "employee@example.test", calendarName: "Work", timeZoneID: "America/New_York")
        let task = SourceCollectionTask.calendar(CalendarReadRequest(source: source, day: Date()))
        #expect(task.setupChecklist.hasPrefix("open Calendar, signed in as employee@example.test, with the Work calendar showing."))
        #expect(task.nothingSavedMessage(reply: " \n", rejection: nil)
                == "Noteling read this source but saved nothing new, so your earlier results are kept. Before running it again, " + task.setupChecklist)
    }

    @Test func aJobOpensItsOwnPageAndItsResultShowsWhatItAssumed() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        let opening = "Noteling opened the saved address in a new Google Chrome tab for this read."
        let summary = "Read Inbox (employee@example.test), today in New York time; couldn't check which were unread, so this includes all of today's."
        var lines: [String] = []
        var opened: [UUID] = []
        let runner = fixture.runner { _, _, messages, executor in
            #expect(ReadingCollectionRunnerTests.text(messages).contains(opening))
            _ = await executor("read_screen", [:], nil)
            var payload = try fixture.payload(messages: messages)
            payload["summary"] = summary
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            return "Finished"
        }
        runner.log = { lines.append($0) }
        runner.openSource = { source in opened.append(source.id); return opening }

        await (try #require(runner.collect(source: fixture.mail, requestedAt: fixture.day))).value

        #expect(opened == [fixture.mail.id])
        #expect(lines.contains("run: “Gmail inbox”: " + opening))
        #expect(fixture.store.latestReading(for: fixture.mail.id)?.summary == summary)
        let entry = try #require(fixture.store.runStore.runs.first?.entries.first)
        #expect(entry.message == "Saved 1 item. " + summary)
        #expect(lines.contains { $0.hasPrefix("run: “Gmail inbox” complete") && $0.contains("today in New York time") })
    }

    @Test func aReadWithoutASummaryStillShowsTheAccountItSawAndWhatItCouldNotCheck() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let request = ReadingReadRequest(source: fixture.mail, requestedAt: fixture.day)
        let complete = try ReadingSubmission.parse(fixture.payload(source: fixture.mail, requestID: request.id), request: request)
        #expect(complete.summary == nil)
        #expect(complete.assumptions == "Account seen: Account menu displays employee@example.test.")
        let partial = try ReadingSubmission.parse(fixture.payload(source: fixture.mail, requestID: request.id, coverage: .partial), request: request)
        #expect(partial.assumptions == "Account seen: Account menu displays employee@example.test. Couldn't check: Only the visible inbox list was readable; more messages remain")
    }

    @Test func aScriptJobReadsWithoutTheModelOrComputerControl() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let job = LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My inbox", application: "Mail",
                                       scope: "Skip promotions", script: "mail__today")
        try fixture.store.saveReadingSource(job)
        var modelCalls = 0
        var lines: [String] = []
        let runner = fixture.runner(allowControl: false) { _, _, _, _ in modelCalls += 1; return "unexpected" }
        runner.log = { lines.append($0) }
        runner.readScript = { source in
            #expect(source.id == job.id)
            return ["account": "me@example.test", "mailbox": "INBOX", "arrived": 2, "items": [
                ["key": "a@example.test", "title": "Invoice due Friday", "from": "Billing"],
                ["key": "b@example.test", "title": "Team lunch", "from": "Sam"]]]
        }

        await (try #require(runner.collect(source: job, requestedAt: fixture.day))).value

        #expect(modelCalls == 0)
        let entry = try #require(fixture.store.runStore.runs.first?.entries.first)
        #expect(entry.state == .complete)
        #expect(entry.readingSnapshot?.items.count == 2)
        #expect(entry.message.hasPrefix("Saved 2 items. Read all 2 messages that arrived in INBOX since "))
        #expect(lines.contains { $0.hasPrefix("run: “Morning mail” complete") })
    }

    @Test func stoppingAScriptJobKeepsTheEarlierResults() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let job = LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My inbox", application: "Mail",
                                       scope: "Skip promotions", script: "imap-mail__today")
        try fixture.store.saveReadingSource(job)
        let runner = fixture.runner(allowControl: false) { _, _, _, _ in "unexpected" }
        runner.readScript = { _ in
            _ = runner.stopActive()   // the person presses Stop while the script is still reading
            return ["mailbox": "INBOX", "arrived": 1, "items": [["key": "a@example.test", "title": "Late result"]]]
        }

        await (try #require(runner.collect(source: job, requestedAt: fixture.day))).value

        let entry = try #require(fixture.store.runStore.runs.first?.entries.first)
        #expect(entry.state == .stopped)
        #expect(entry.readingSnapshot == nil)
        #expect(entry.message.hasSuffix("stopped. The previous saved collection was kept."))
    }

    @Test func aScriptJobThatCannotConnectSaysWhy() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let job = LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My inbox", application: "Mail",
                                       scope: "Skip promotions", script: "mail__today")
        try fixture.store.saveReadingSource(job)
        var lines: [String] = []
        let runner = fixture.runner(allowControl: false) { _, _, _, _ in "unexpected" }
        runner.log = { lines.append($0) }
        runner.readScript = { _ in ["error": "Mail isn't connected yet: add MAIL_ADDRESS and MAIL_APP_PASSWORD in Noteling Settings."] }

        await (try #require(runner.collect(source: job, requestedAt: fixture.day))).value

        let entry = try #require(fixture.store.runStore.runs.first?.entries.first)
        #expect(entry.state == .failed)
        #expect(entry.message == "Noteling couldn't read this source: Mail isn't connected yet: add MAIL_ADDRESS and MAIL_APP_PASSWORD in Noteling Settings.")
        #expect(lines.contains { $0.hasPrefix("run: “Morning mail” failed") && $0.contains("isn't connected yet") })
    }

    @Test func aScriptJobReadsBackToItsLastSortedReadThroughTheToolsFolder() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // Real scripts in a real tools folder, run with no readScript hook. Each says how far back it was asked to read.
        let pack = fixture.registry.root.appendingPathComponent("mail")
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "---\nname: Mail\nsources: [today, plain]\n---\nReads mail.".write(to: pack.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try """
        def run(since_hours: int = 24, last_read: str = "") -> dict:
            \"\"\"Fixture mail read.\"\"\"
            title = f"Read back {since_hours} hours" + (f" to {last_read}" if last_read else "")
            return {"mailbox": "INBOX", "arrived": 1, "items": [{"key": "a@example.test", "title": title}]}
        """.write(to: pack.appendingPathComponent("scripts/today.py"), atomically: true, encoding: .utf8)
        try """
        def run() -> dict:
            \"\"\"Fixture read that takes no arguments.\"\"\"
            return {"mailbox": "INBOX", "arrived": 1, "items": [{"key": "b@example.test", "title": "Read its own window"}]}
        """.write(to: pack.appendingPathComponent("scripts/plain.py"), atomically: true, encoding: .utf8)
        await fixture.registry.reload()
        try #require(fixture.registry.script(named: "mail__today") != nil && fixture.registry.script(named: "mail__plain") != nil)

        func job(_ name: String, _ script: String) throws -> LearnedReadingSource {
            let job = LearnedReadingSource(kind: .mail, name: name, meaning: "My inbox", application: "Mail",
                                           scope: "Skip promotions", script: script)
            try fixture.store.saveReadingSource(job)
            return job
        }
        let fresh = try job("New mail", "mail__today"), skipped = try job("Morning mail", "mail__today")
        let twice = try job("Work mail", "mail__today"), plain = try job("Other mail", "mail__plain")
        /// Saves a read of `source` at `at` and returns its run.
        func saved(_ source: LearnedReadingSource, at: Date, title: String) throws -> UUID {
            let result: [String: Any] = ["mailbox": "INBOX", "arrived": 1, "items": [["key": "c@example.test", "title": title]]]
            let snapshot = try ScriptReading.snapshot(from: result, request: ReadingReadRequest(source: source, requestedAt: at), collectedAt: at)
            try fixture.store.saveReadingSnapshot(snapshot)
            return try #require(fixture.store.runStore.runs.first { $0.entries.first?.readingSnapshot?.id == snapshot.id }?.id)
        }
        // The last reads a card step sorted, which have receipts: 29½ hours ago, so a day was skipped, and 10½ hours
        // ago for a job read twice a day. There is no attention test at all, so nothing here depends on it.
        let skippedDay = Date().addingTimeInterval(-29.5 * 3_600), thisMorning = Date().addingTimeInterval(-10.5 * 3_600)
        let receipts = [try saved(skipped, at: skippedDay, title: "Sorted read"), try saved(plain, at: skippedDay, title: "Sorted read"),
                        try saved(twice, at: thisMorning, title: "Sorted read")]
        // Each was read again 15 minutes ago, but no card step sorted that read: its step failed, or was stopped. It
        // moves nothing, so the mail since the sorted read is read again.
        for source in [skipped, twice, plain] { _ = try saved(source, at: Date().addingTimeInterval(-0.25 * 3_600), title: "Unsorted read") }
        // Wired as the app wires it: the run IDs the card step's receipts cover.
        let runner = fixture.runner(allowControl: false) { _, _, _, _ in "unexpected" }
        runner.sortedRunIDs = { Set(receipts) }
        func read(_ source: LearnedReadingSource) async throws -> SourceRunEntry {
            await (try #require(runner.collect(source: source))).value
            return try #require(fixture.store.runStore.runs.first?.entries.first { $0.sourceID == source.id })
        }
        func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

        // Each job's window is its own: one no card step sorted looks back the usual day, whatever the others read,
        // and has no last read to count what it cut off from.
        #expect(try await read(fresh).readingSnapshot?.items.map(\.title) == ["Read back 24 hours"])
        // Whole hours since the sorted read, plus one: 31 after a skipped day, and 12, not a whole day, twice a day.
        #expect(try await read(skipped).readingSnapshot?.items.map(\.title) == ["Read back 31 hours to \(iso(skippedDay))"])
        #expect(try await read(twice).readingSnapshot?.items.map(\.title) == ["Read back 12 hours to \(iso(thisMorning))"])
        // A script that doesn't take since_hours is called as before, even after a skipped day.
        let other = try await read(plain)
        #expect(other.state == .complete && other.readingSnapshot?.items.map(\.title) == ["Read its own window"])
    }

    @Test func aSourceRunHasRoomForItsFindingsWhateverTheReplyLengthSetting() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        let runner = fixture.runner { _, _, _, _ in "Nothing new." }
        await (try #require(runner.collect(source: fixture.mail, requestedAt: fixture.day))).value
        #expect(Config().maxTokens < CalendarCollectionRunner.minimumReplyTokens)
        #expect(fixture.lastClient?.maxTokens == CalendarCollectionRunner.minimumReplyTokens)
    }

    @Test func aReadThatRanOutOfRoomSaysSo() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        let runner = fixture.runner { _, _, _, _ in "Collecting 25 messages.\n\n" + ClaudeClient.cutOffNote }
        await (try #require(runner.collect(source: fixture.mail, requestedAt: fixture.day))).value
        let message = try #require(fixture.store.runStore.runs.first?.entries.first?.message)
        #expect(message.contains("It ran out of room before it could save its findings."))
        #expect(!message.contains(ClaudeClient.cutOffNote))
    }

    @Test func aSourceTurnedDownBeforeReadingIsLoggedWithWhatToFix() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let noRules = LearnedReadingSource(kind: .mail, name: "Mail inbox", meaning: "My incoming mail", application: "Mail",
                                           bundleID: "com.apple.mail")
        let noAccount = LearnedReadingSource(kind: .mail, name: "Mail app inbox", meaning: "My incoming mail", application: "Mail",
                                             bundleID: "com.apple.mail", scope: "Only unread messages from today")
        try fixture.store.saveReadingSource(noRules)
        try fixture.store.saveReadingSource(noAccount)
        var lines: [String] = []
        var readers = 0
        let runner = fixture.runner { _, _, _, _ in readers += 1; return "Nothing new." }
        runner.log = { lines.append($0) }

        await (try #require(runner.collectAll(day: fixture.day))).value

        let line = try #require(lines.first { $0.hasPrefix("run: “Mail inbox” failed before reading: ") })
        #expect(line.contains("Its reading rules are empty"))
        #expect(readers == 1)   // the job without an account still runs
        #expect(lines.contains { $0.hasPrefix("run: “Mail app inbox” failed after") })
        let message = try #require(fixture.store.runStore.runs.first?.entries.first { $0.sourceName == "Mail inbox" }?.message)
        #expect(message.hasPrefix("Noteling didn't start this source. Its reading rules are empty"))
        #expect(message.hasSuffix("Fix it in Manage sources (Edit source), or say what to change in chat."))

        lines = []
        #expect(runner.collect(source: noRules) == nil)
        #expect(lines.contains { $0.hasPrefix("run: “Mail inbox” failed before reading: Noteling didn't start this source.") })
    }

    @Test func freshReadingIsRequiredAndNavigationAndInvalidReplacementDiscardStagedMail() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        let previous = try fixture.seedReading()
        let runner = fixture.runner { _, _, messages, executor in
            let payload = try fixture.payload(messages: messages)
            #expect((await executor("submit_reading_collection", payload, nil)).isError)
            _ = await executor("read_screen", [:], nil)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            _ = await executor("target_window", ["select": 1], nil)
            #expect((await executor("submit_reading_collection", payload, nil)).isError)
            _ = await executor("read_screen", [:], nil)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            var wrongRequest = payload
            wrongRequest["requestID"] = UUID().uuidString
            #expect((await executor("submit_reading_collection", wrongRequest, nil)).isError)
            return "The inbox was collected; this prose must not commit prior staged observations."
        }
        let task = try #require(runner.collect(source: fixture.mail, requestedAt: fixture.day))
        await task.value
        #expect(runner.error?.contains("saved nothing new") == true)
        #expect(fixture.store.latestReading(for: fixture.mail.id) == previous)
        #expect(fixture.desktop.tasks.history.first?.outcome == .failed)
    }

    @Test func partialReadOfSavedURLWithUnknownAccountPreservesObservedScopeAndIgnoresFinalClaims() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var source = fixture.mail
        source.account = ""
        try fixture.store.saveReadingSource(source)
        let runner = fixture.runner { system, _, messages, executor in
            #expect(system.contains("Do not switch accounts"))
            #expect(system.contains("Verify the saved URL"))
            #expect(Self.text(messages).replacingOccurrences(of: "\\/", with: "/").contains(source.url))
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.payload(source: source, messages: messages, coverage: .partial)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            return "I replied and read every message in the whole mailbox."
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        await task.value
        #expect(runner.batchResults.map(\.state) == [.partial])
        let saved = try #require(fixture.store.latestReading(for: source.id))
        #expect(saved.coverage == .partial)
        #expect(saved.accountEvidence == "Account menu displays employee@example.test")
        #expect(saved.coverageNotes == ["Only the visible inbox list was readable; more messages remain"])
        let result = try #require(fixture.desktop.tasks.history.first)
        #expect(result.text == ReadingBriefing.render(saved))
        #expect(!result.text.contains("I replied"))
        #expect(result.text.contains("No account identity was saved"))
    }

    @Test func cancellingReadingBatchRetainsCompletedMailAndNeverStartsRemainingSource() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var second = fixture.mail
        second.id = UUID(); second.name = "Second mailbox"; second.url = "https://mail.google.com/mail/u/1/#inbox"
        var third = fixture.mail
        third.id = UUID(); third.name = "Third mailbox"; third.url = "https://mail.google.com/mail/u/2/#inbox"
        let sources = [fixture.mail, second, third]
        for source in sources { try fixture.store.saveReadingSource(source) }
        var calls: [UUID] = []
        var secondEntered = false
        let runner = fixture.runner { _, _, messages, executor in
            let source = try #require(sources.first { Self.text(messages).contains($0.id.uuidString) })
            calls.append(source.id)
            _ = await executor("read_screen", [:], nil)
            let payload = try fixture.payload(source: source, messages: messages)
            #expect(!(await executor("submit_reading_collection", payload, nil)).isError)
            if source.id == second.id {
                secondEntered = true
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return "Read"
        }
        let task = try #require(runner.collectAll(day: fixture.day))
        try await until { secondEntered }
        #expect(runner.stopActive())
        await task.value
        #expect(calls == [fixture.mail.id, second.id])
        #expect(runner.batchResults.map(\.state) == [.complete, .stopped, .notRun])
        #expect(fixture.store.latestReading(for: fixture.mail.id) != nil)
        #expect(fixture.store.latestReading(for: second.id) == nil)
        #expect(fixture.store.latestReading(for: third.id) == nil)
        #expect(!runner.isRunning)
    }

    @Test func sourceReadNativeToolsDoNotExposeScriptsMutationOrImplicitForegroundObservation() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.mail)
        var settings = Config(); settings.allowControl = true
        let runner = CalendarCollectionRunner(store: fixture.store, desktop: fixture.desktop, registry: fixture.registry,
            activities: fixture.activities, config: { settings }, makeClient: { _ in FakeClient { _, tools, _, executor in
                let names = Set(tools.compactMap { $0["name"] as? String })
                #expect(names == ["target_window", "read_screen", "look_at_screen", "find_on_screen", "click_element", "reading_scroll", "submit_reading_collection"])
                #expect(fixture.desktop.control.target == nil)
                #expect(fixture.desktop.control.pressRefusal != nil)
                for name in ["type", "key", "left_click", "send_message", "ask_for_the_mouse", "read_file", "grep", "calendar_scroll"] {
                    #expect((await executor(name, [:], nil)).isError)
                    #expect((await executor(name, [:], "computer")).isError)
                }
                #expect((await executor("read_screen", [:], nil)).isError)
                return "No source window selected"
            } })
        let task = try #require(runner.collect(source: fixture.mail))
        await task.value
        #expect(fixture.store.readingSnapshots.isEmpty)
        #expect(fixture.activities.current == nil)
        #expect(!fixture.desktop.isBusy)
        #expect(fixture.desktop.control.pressRefusal == nil)
    }

    @Test func readingPolicyAllowsOnlyListNavigationAndRefusesMailRowsBodyLinksAndMutations() {
        for title in ["Inbox", "Primary", "Social", "Older", "Newer", "Next page", "Previous page", "Refresh", "Inbox (3)"] {
            #expect(ReadingNavigationPolicy.refusal(.init(role: "AXButton", title: title)) == nil)
        }
        for title in ["Compose", "Reply", "Reply all", "Forward", "Send", "Archive", "Delete", "Star", "Mark as read", "Select", "Labels", "Settings", "Switch account", "Unknown control"] {
            #expect(ReadingNavigationPolicy.refusal(.init(role: "AXButton", title: title)) != nil)
        }
        for role in ["AXRow", "AXCell", "AXLink", "AXCheckBox", "AXTextField"] {
            #expect(ReadingNavigationPolicy.refusal(.init(role: role, title: "Inbox")) != nil)
        }
        #expect(ReadingNavigationPolicy.refusal(.init(role: "AXButton", title: "Inbox", description: "Delete messages")) != nil)
        #expect(ReadingNavigationPolicy.refusal(.init(role: "AXButton", title: "Primary", isDefaultButton: true)) != nil)
    }

    private static func text(_ messages: [[String: Any]]) -> String {
        ((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func until(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(condition())
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reading-runner-\(UUID().uuidString)")
        let activities = NativeActivityGate()
        let day = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        let mail = LearnedReadingSource(kind: .mail, name: "Gmail inbox", meaning: "My incoming work mail",
            application: "Google Chrome", bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox",
            account: "employee@example.test", scope: "The first page of the Primary inbox",
            navigationHints: "Recognize Inbox and Primary in the saved Gmail tab", completionChecks: "Verify account, tab and displayed page range")
        let calendar = LearnedCalendarSource(name: "Work schedule", meaning: "My work meetings", application: "Outlook",
            bundleID: "com.microsoft.Outlook", account: "employee@example.test", calendarName: "Calendar", timeZoneID: "America/New_York")
        lazy var store = CalendarStore(directory: directory.appendingPathComponent("store"))
        var lastClient: FakeClient?
        lazy var desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
        lazy var registry = ToolRegistry(root: directory.appendingPathComponent("tools"), runner: ScriptRunner(config: Config()))

        func payload(source: LearnedReadingSource? = nil, messages: [[String: Any]], coverage: CalendarCoverage = .complete) throws -> [String: Any] {
            let marker = "Required requestID: "
            let line = try #require(ReadingCollectionRunnerTests.text(messages).components(separatedBy: .newlines).first { $0.hasPrefix(marker) })
            let id = try #require(UUID(uuidString: String(line.dropFirst(marker.count))))
            return payload(source: source ?? mail, requestID: id, coverage: coverage)
        }

        func payload(source: LearnedReadingSource, requestID: UUID, coverage: CalendarCoverage = .complete) -> [String: Any] {
            ["sourceID": source.id.uuidString, "requestID": requestID.uuidString, "coverage": coverage.rawValue,
             "coverageNotes": coverage == .complete ? ["Verified the full taught first page"] : ["Only the visible inbox list was readable; more messages remain"],
             "accountEvidence": "Account menu displays employee@example.test", "sourceEvidence": "Address bar: \(source.url)",
             "scopeEvidence": "Inbox selected, Primary tab, 1–1 of 1 on the page",
             "items": [["title": "Fresh incoming message", "text": "Taylor · Current visible snippet · 9:42 AM", "evidence": "Visible inbox row with subject, sender, snippet and displayed time"]]]
        }

        func seedReading() throws -> ReadingSnapshot {
            let request = ReadingReadRequest(source: mail, requestedAt: day)
            let snapshot = try ReadingSubmission.parse(payload(source: mail, requestID: request.id), request: request)
            try store.saveReadingSnapshot(snapshot)
            return snapshot
        }

        func calendarPayload() -> [String: Any] {
            ["sourceID": calendar.id.uuidString, "day": "2026-09-28", "timeZoneID": calendar.timeZoneID,
             "coverage": "complete", "coverageNotes": ["All hours inspected"], "accountEvidence": "employee@example.test",
             "calendarEvidence": "Calendar selected", "dateEvidence": "September 28 2026 Eastern time",
             "events": [["title": "Work review", "start": "2026-09-28T09:00:00-04:00", "end": "2026-09-28T10:00:00-04:00",
                         "allDay": false, "response": "accepted", "availability": "busy", "isCancelled": false, "evidence": "Work review 9–10 accepted busy"]]]
        }

        func runner(allowControl: Bool = true, _ body: @escaping FakeClient.Body) -> CalendarCollectionRunner {
            var settings = Config(); settings.allowControl = allowControl
            return CalendarCollectionRunner(store: store, desktop: desktop, registry: registry, activities: activities,
                config: { settings }, makeClient: { _ in let client = FakeClient(body); self.lastClient = client; return client }, prepareExecution: { _, additional, evidence in
                    let read = ToolRoute(match: .tool(name: "read_screen"), definition: ["name": "read_screen"]) { _, _, _ in
                        evidence.observed(); return .text("Fresh observed source")
                    }
                    let navigate = ToolRoute(match: .tool(name: "target_window"), definition: ["name": "target_window"]) { _, _, _ in
                        evidence.navigated(); return .text("Navigation completed")
                    }
                    return PreparedExecution(system: "fixture", router: try ToolRouter(routes: additional + [read, navigate]))
                })
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
            let result = try await body(system, tools, messages, executor)
            messages.append(["role": "assistant", "content": [["type": "text", "text": result]]])
            return ClaudeReply(text: result, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 0)
        }
    }
}
