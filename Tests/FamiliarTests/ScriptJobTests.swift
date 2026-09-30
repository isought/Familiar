import Foundation
import Testing
@testable import Familiar

/// Jobs that read through a tools-folder script: which scripts can feed a job, how bundled packs reach existing
/// installs, how a script's result becomes a run's findings, and how a job's rules reach the card step.
@Suite @MainActor
struct ScriptJobTests {
    @Test func aPackListsTheScriptsThatCanFeedAJob() async throws {
        let root = temporary("script-packs")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("---\nname: Mail\nrequires: [MAIL_ADDRESS, MAIL_APP_PASSWORD]\nsources: [today]\n---\nReads mail.",
                  to: root.appendingPathComponent("mail/SKILL.md"))
        let registry = ToolRegistry(root: root, runner: ScriptRunner(config: Config()))
        await registry.reload()
        let pack = try #require(registry.packs.first)
        pack.scripts = ["today", "search"].map { stem in
            ScriptTool(id: "mail__\(stem)", packDir: "mail", fileName: "\(stem).py", path: pack.dir.appendingPathComponent("scripts/\(stem).py"),
                       description: "Fixture", inputSchema: ["type": "object", "properties": [:]], dependencies: [])
        }

        #expect(pack.sources == ["today"])
        #expect(registry.sourceScripts().map(\.script.id) == ["mail__today"])
        #expect(registry.pack(holdingScript: "mail__today")?.requires == ["MAIL_ADDRESS", "MAIL_APP_PASSWORD"])
    }

    @Test func aPackAddedInAnUpdateReachesAnExistingInstallOnce() throws {
        let bundled = temporary("bundled"), root = temporary("installed")
        defer { [bundled, root].forEach { try? FileManager.default.removeItem(at: $0) } }
        for pack in ["expenses", "waxwing", "mail"] { try write("---\nname: \(pack)\n---", to: bundled.appendingPathComponent("\(pack)/SKILL.md")) }
        try write("---\nname: edited expenses\n---", to: root.appendingPathComponent("expenses/SKILL.md"))
        try write("---\nname: gmail\n---", to: root.appendingPathComponent("gmail/SKILL.md"))   // taught with Watch Me

        #expect(ToolRegistry.addMissingPacks(from: bundled, to: root) == ["mail"])   // waxwing was removed on purpose
        #expect(try String(contentsOf: root.appendingPathComponent("expenses/SKILL.md"), encoding: .utf8).contains("edited"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("waxwing").path))

        try FileManager.default.removeItem(at: root.appendingPathComponent("mail"))
        #expect(ToolRegistry.addMissingPacks(from: bundled, to: root).isEmpty)       // removed after it arrived: stays removed
    }

    @Test func aFreshInstallThatWasSeededGetsNothingTwice() throws {
        let bundled = temporary("bundled"), root = temporary("fresh")
        defer { [bundled, root].forEach { try? FileManager.default.removeItem(at: $0) } }
        try write("---\nname: mail\n---", to: bundled.appendingPathComponent("mail/SKILL.md"))
        try FileManager.default.copyItem(at: bundled, to: root)
        #expect(ToolRegistry.addMissingPacks(from: bundled, to: root).isEmpty)
    }

    @Test func aMailScriptResultBecomesTheRunsFindingsWithExactCounts() throws {
        let request = ReadingReadRequest(source: mailJob())
        let result: [String: Any] = [
            "account": "me@example.test", "server": "imap.example.test", "mailbox": "INBOX", "since": "2026-09-29T11:00:00+00:00",
            "arrived": 3, "returned": 3, "truncated": false, "items": [
                ["key": "a@example.test", "title": "Invoice due Friday", "from": "Billing <billing@example.test>",
                 "received": "2026-09-30T08:10:00+00:00", "unread": true, "tab": "primary", "important": true,
                 "preview": "Your invoice is attached.", "url": "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Aa"],
                ["key": "b@example.test", "title": "50% off everything", "from": "Shop <deals@example.test>",
                 "received": "2026-09-30T07:00:00+00:00", "unread": false, "tab": "promotions", "bulk": true, "preview": ""],
                ["key": "a@example.test", "title": "Invoice due Friday", "from": "Billing <billing@example.test>"],   // delivered twice
            ]]

        let snapshot = try ScriptReading.snapshot(from: result, request: request)

        #expect(snapshot.items.map(\.title) == ["Invoice due Friday", "50% off everything"])
        #expect(snapshot.coverage == .complete)
        #expect(snapshot.summary?.hasPrefix("Read all 3 messages that arrived in INBOX since ") == true)
        #expect(snapshot.accountEvidence == "Signed in as me@example.test")
        let invoice = snapshot.items[0], sale = snapshot.items[1]
        #expect(invoice.text.hasPrefix("From Billing <billing@example.test> · "))
        #expect(invoice.text.contains("unread · Primary tab · marked important by Gmail\nYour invoice is attached."))
        #expect(invoice.identityKey == "a@example.test")
        #expect(invoice.url.hasPrefix("https://mail.google.com/"))
        #expect(sale.text.contains("read · Promotions tab · sent to a mailing list"))
        try snapshot.validate()
    }

    @Test func aCutOffListIsPartialAndSaysHowManyArrived() throws {
        let rows = (0..<3).map { ["key": "m\($0)@example.test", "title": "Message \($0)"] }
        let snapshot = try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": 640, "truncated": true, "items": rows],
                                                  request: ReadingReadRequest(source: mailJob()))
        #expect(snapshot.coverage == .partial)
        #expect(snapshot.coverageNotes == ["640 messages arrived; the newest 3 are here."])
        #expect(snapshot.summary?.hasPrefix("Read the newest 3 of 640 messages") == true)
    }

    @Test func aScriptErrorIsThePlainReasonAndNothingArrivedIsAnEmptyRead() throws {
        let request = ReadingReadRequest(source: mailJob())
        #expect(throws: CalendarDataError.self) { try ScriptReading.snapshot(from: ["error": "Mail isn't connected yet."], request: request) }
        do { _ = try ScriptReading.snapshot(from: ["error": "Mail isn't connected yet."], request: request) }
        catch { #expect(error.localizedDescription == "Mail isn't connected yet.") }

        let empty = try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": 0, "items": [[String: Any]]()], request: request)
        #expect(empty.items.isEmpty && empty.coverage == .complete)
        #expect(empty.summary?.hasPrefix("Nothing arrived in INBOX since") == true)
    }

    @Test func aScriptJobNeedsNoWindowAndMayHoldAWholeInbox() throws {
        var job = mailJob()
        try job.validateForRead()
        #expect(job.readsThroughScript)
        job.script = nil
        #expect(throws: CalendarDataError.self) { try job.validate() }   // nothing identifies where it reads
    }

    @Test func aJobsOwnRulesReachTheCardStep() throws {
        let directory = temporary("card-rules")
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = mailJob(), other = UUID()
        let observation = CardObservation(runID: UUID(), sourceID: job.id, itemKey: "a@example.test", sourceName: job.name, kind: "mail",
            title: "50% off everything", excerpt: "From Shop", url: "", identityEvidence: "Message-ID a@example.test",
            observedAt: Date(), state: .unknown, stateEvidence: "")
        let rules = [SourceRules(sourceID: job.id, sourceName: job.name, meaning: job.meaning, readingRules: job.scope),
                     SourceRules(sourceID: other, sourceName: "Another job", meaning: "x", readingRules: "Only invoices")]

        let plan = try CardGenerationSubmission(observations: [observation], rules: rules).plan(morning: MorningStore(directory: directory))
        let prompt = plan.content.compactMap { $0["text"] as? String }.joined()

        #expect(prompt.contains("\"sourceRules\""))
        #expect(prompt.contains("Skip newsletters and promotions"))
        #expect(!prompt.contains("Only invoices"))   // only the rules of sources in this batch
        #expect(CardGenerationSubmission.system.contains("sourceRules are the person's own rules"))
    }

    @Test func theCardStepGetsEachJobsCurrentRulesFromSavedRuns() throws {
        let directory = temporary("card-rules-saved")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CalendarStore(directory: directory)
        var job = mailJob()
        try store.saveReadingSource(job)
        let result: [String: Any] = ["mailbox": "INBOX", "arrived": 1, "items": [["key": "a@example.test", "title": "Invoice"]]]
        try store.saveReadingSnapshot(ScriptReading.snapshot(from: result, request: ReadingReadRequest(source: job)))

        let input = CardGenerationInput.saved(in: store, runID: nil, excluding: [])
        #expect(input.rules == [SourceRules(sourceID: job.id, sourceName: job.name, meaning: job.meaning, readingRules: job.scope)])

        job.scope = "Only invoices"   // changed in chat after the run: today's rules win
        try store.saveReadingSource(job)
        #expect(CardGenerationInput.saved(in: store, runID: nil, excluding: []).rules.first?.readingRules == "Only invoices")
    }

    @Test func aCalendarEventReachesTheCardStepWithItsLocalTime() throws {
        let directory = temporary("calendar-when")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CalendarStore(directory: directory)
        let day = ISO8601DateFormatter().date(from: "2026-09-29T13:00:00Z")!
        let source = LearnedCalendarSource(name: "Work", meaning: "Work schedule", application: "Calendar",
            account: "alex@example.test", calendarName: "Work", timeZoneID: "America/New_York")
        try store.saveSource(source)
        let event = CalendarEventRecord(id: "one", title: "Design review", start: day, end: day.addingTimeInterval(3600),
            response: .accepted, availability: .busy, evidence: "Design review 9–10 accepted busy")
        try store.saveSnapshot(CalendarSnapshot(sourceID: source.id, day: day, timeZoneID: source.timeZoneID, events: [event],
            coverage: .complete, accountEvidence: "alex@example.test", calendarEvidence: "Work calendar", dateEvidence: "Sep 29", source: source))

        let excerpt = try #require(CardGenerationInput.saved(in: store, runID: nil, excluding: []).observations.first?.excerpt)
        #expect(excerpt.hasPrefix("When: "))
        #expect(excerpt.contains("9:00") && excerpt.contains("(America/New_York)"))   // 13:00 UTC is 9 AM in New York
    }

    private func mailJob() -> LearnedReadingSource {
        LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My personal inbox", application: "Mail",
                             scope: "Skip newsletters and promotions; show anything that needs a reply", script: "mail__today")
    }

    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
