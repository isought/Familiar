import Foundation
import Testing
@testable import Familiar

/// A script job reads back to the last read a card step sorted, so a skipped day's mail is still read: an hour more
/// than the time since, a week at most, the usual 24 hours with no such read, and only from a script that takes
/// `since_hours`. Which read that is comes from the card step's receipts, never from the attention test.
@Suite @MainActor
struct ScriptReadWindowTests {
    static let now = ISO8601DateFormatter().date(from: "2026-09-30T08:00:00Z")!

    @Test func hours() {
        #expect(ScriptReadWindow.hours(lastRead: nil, now: Self.now) == 24)   // the first read: today's 24 hours
        // Reads twice a day overlap by the hour's margin only, not by a whole day.
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 10), now: Self.now) == 11)
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 3), now: Self.now) == 4)
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 0.25), now: Self.now) == 2)
        #expect(ScriptReadWindow.hours(lastRead: Self.now, now: Self.now) == 1)   // at least an hour
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 23.5), now: Self.now) == 25)
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 30), now: Self.now) == 31)   // yesterday was skipped
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 48.25), now: Self.now) == 50)
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 24 * 10), now: Self.now) == 168)   // the script reads a week at most
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: -2), now: Self.now) == 24)   // a clock set back: the usual day
    }

    @Test func theLastReadIsTheNewestACardStepSorted() throws {
        let job = mailJob(), other = mailJob(), never = mailJob()
        let runs = [
            run(try entry(job, .complete, collectedAt: ago(hours: 50))),
            run(try entry(job, .partial, collectedAt: ago(hours: 30)), try entry(other, .complete, collectedAt: ago(hours: 30))),
            run(try entry(job, .stopped), try entry(other, .complete, collectedAt: ago(hours: 1))),
            run(try entry(job, .failed, collectedAt: ago(hours: 2))),   // a failed read never moves the window, findings or not
            run(try entry(job, .interrupted), try entry(never, .failed)),
            run(try entry(job, .complete, collectedAt: ago(hours: 0.25))),   // read, but its card step failed or was stopped
        ]
        let sorted = Set(runs.prefix(5).map(\.id))

        // Newest by when the findings were collected, wherever the run sits in the list, among the runs a receipt covers.
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: runs, sorted: sorted) == ago(hours: 30))
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: runs.reversed(), sorted: sorted) == ago(hours: 30))
        #expect(ScriptReadWindow.lastRead(sourceID: other.id, runs: runs, sorted: sorted) == ago(hours: 1))
        #expect(ScriptReadWindow.lastRead(sourceID: never.id, runs: runs, sorted: sorted) == nil)
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: [], sorted: sorted) == nil)
        // No card step has sorted anything, say on the first morning: the usual day, however recent the reads.
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: runs, sorted: []) == nil)
        // Once the newest read is sorted, it is the last read.
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: runs, sorted: Set(runs.map(\.id))) == ago(hours: 0.25))
    }

    @Test func onlyAScriptThatDeclaresSinceHoursIsGivenIt() {
        let mail = tool(["since_hours": ["type": "integer"], "mailbox": ["type": "string"], "limit": ["type": "integer"]])
        let args = ScriptReadWindow.arguments(for: mail, lastRead: ago(hours: 30), now: Self.now)
        #expect(Array(args.keys) == ["since_hours"] && args["since_hours"] as? Int == 31)   // the limit stays the script's own
        #expect(ScriptReadWindow.arguments(for: mail, lastRead: nil, now: Self.now)["since_hours"] as? Int == 24)

        #expect(ScriptReadWindow.arguments(for: tool(["query": ["type": "string"]]), lastRead: ago(hours: 30), now: Self.now).isEmpty)
        #expect(ScriptReadWindow.arguments(for: tool(nil), lastRead: ago(hours: 30), now: Self.now).isEmpty)
    }

    /// A script that takes `last_read` is told when the last sorted read was, so it can count what it cut off since.
    @Test func aScriptThatDeclaresLastReadIsToldIt() {
        let mail = tool(["since_hours": ["type": "integer"], "last_read": ["type": "string"]])
        let args = ScriptReadWindow.arguments(for: mail, lastRead: ago(hours: 30), now: Self.now)
        #expect(args["since_hours"] as? Int == 31 && args["last_read"] as? String == "2026-09-29T02:00:00Z")
        // With no sorted read, or one the Mac's clock puts in the future, there is none to count from.
        #expect(Array(ScriptReadWindow.arguments(for: mail, lastRead: nil, now: Self.now).keys) == ["since_hours"])
        #expect(Array(ScriptReadWindow.arguments(for: mail, lastRead: ago(hours: -2), now: Self.now).keys) == ["since_hours"])
    }

    @Test func theBundledMailScriptDeclaresSinceHoursAndLastRead() throws {
        // The schema the tools folder builds from the script, made by the same helper.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Resources/py/introspect.py").path,
                             root.appendingPathComponent("tools/imap-mail/scripts/today.py").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let json = try #require(ScriptRunner.lastJSONLine(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
        let schema = try #require(json["input_schema"] as? [String: Any])
        var today = tool(nil)
        today.inputSchema = schema
        let args = ScriptReadWindow.arguments(for: today, lastRead: ago(hours: 30), now: Self.now)
        #expect(args["since_hours"] as? Int == 31 && args["last_read"] as? String == "2026-09-29T02:00:00Z")
        let description = (schema["properties"] as? [String: Any])?["since_hours"].flatMap { ($0 as? [String: Any])?["description"] as? String }
        #expect(description?.contains("1 to \(ScriptReadWindow.maximumHours)") == true)
    }

    private func ago(hours: Double) -> Date { Self.now.addingTimeInterval(-hours * 3_600) }

    /// A job's entry in a run; a successful one holds what the script returned, collected at `collectedAt`.
    private func entry(_ source: LearnedReadingSource, _ state: SourceRunEntry.State, collectedAt: Date? = nil) throws -> SourceRunEntry {
        let request = ReadingReadRequest(source: source, requestedAt: collectedAt ?? Self.now)
        var entry = SourceRunEntry(reading: request, state: state)
        if let collectedAt {
            let result: [String: Any] = ["mailbox": "INBOX", "arrived": 1, "truncated": state == .partial,
                                         "items": [["key": "a@example.test", "title": "Invoice due Friday"]]]
            entry.readingSnapshot = try ScriptReading.snapshot(from: result, request: request, collectedAt: collectedAt)
        }
        return entry
    }

    private func run(_ entries: SourceRunEntry...) -> SourceRunRecord {
        SourceRunRecord(origin: entries.count > 1 ? .all : .single, startedAt: entries[0].requestedAt, timeZoneID: "UTC", entries: entries)
    }

    private func mailJob() -> LearnedReadingSource {
        LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My personal inbox", application: "Mail",
                             scope: "Skip newsletters and promotions; show anything that needs a reply", script: "mail__today")
    }

    private func tool(_ properties: [String: Any]?) -> ScriptTool {
        ScriptTool(id: "mail__today", packDir: "mail", fileName: "today.py", path: URL(fileURLWithPath: "/tmp/mail/scripts/today.py"),
                   description: "Fixture", inputSchema: properties.map { ["type": "object", "properties": $0] } ?? ["type": "object"],
                   dependencies: [])
    }
}
