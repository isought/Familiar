import Foundation
import Testing
@testable import Familiar

/// A script job reads back to its source's last read, so a skipped day's mail is still read: the usual 24 hours at
/// least, a week at most, and only from a script that takes `since_hours`.
@Suite @MainActor
struct ScriptReadWindowTests {
    static let now = ISO8601DateFormatter().date(from: "2026-09-30T08:00:00Z")!

    @Test func hours() {
        #expect(ScriptReadWindow.hours(lastRead: nil, now: Self.now) == 24)   // the first read: today's 24 hours
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 3), now: Self.now) == 24)
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 23.5), now: Self.now) == 25)
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 30), now: Self.now) == 31)   // yesterday was skipped
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: 24 * 10), now: Self.now) == 168)   // the script reads a week at most
        #expect(ScriptReadWindow.hours(lastRead: ago(hours: -2), now: Self.now) == 24)   // a clock set back
    }

    @Test func lastReadIgnoresFailedAndOtherSources() throws {
        let job = mailJob(), other = mailJob(), never = mailJob()
        let runs = [
            run(try entry(job, .complete, collectedAt: ago(hours: 50))),
            run(try entry(job, .partial, collectedAt: ago(hours: 30)), try entry(other, .complete, collectedAt: ago(hours: 30))),
            run(try entry(job, .stopped), try entry(other, .complete, collectedAt: ago(hours: 1))),
            run(try entry(job, .failed, collectedAt: ago(hours: 2))),   // a failed read never moves the window, findings or not
            run(try entry(job, .interrupted), try entry(never, .failed)),
        ]

        // Newest by when the findings were collected, wherever the run sits in the list.
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: runs) == ago(hours: 30))
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: runs.reversed()) == ago(hours: 30))
        #expect(ScriptReadWindow.lastRead(sourceID: other.id, runs: runs) == ago(hours: 1))
        #expect(ScriptReadWindow.lastRead(sourceID: never.id, runs: runs) == nil)
        #expect(ScriptReadWindow.lastRead(sourceID: job.id, runs: []) == nil)
    }

    @Test func onlyAScriptThatDeclaresSinceHoursIsGivenIt() {
        let mail = tool(["since_hours": ["type": "integer"], "mailbox": ["type": "string"], "limit": ["type": "integer"]])
        let args = ScriptReadWindow.arguments(for: mail, lastRead: ago(hours: 30), now: Self.now)
        #expect(Array(args.keys) == ["since_hours"] && args["since_hours"] as? Int == 31)   // the limit stays the script's own
        #expect(ScriptReadWindow.arguments(for: mail, lastRead: nil, now: Self.now)["since_hours"] as? Int == 24)

        #expect(ScriptReadWindow.arguments(for: tool(["query": ["type": "string"]]), lastRead: ago(hours: 30), now: Self.now).isEmpty)
        #expect(ScriptReadWindow.arguments(for: tool(nil), lastRead: ago(hours: 30), now: Self.now).isEmpty)
    }

    @Test func theBundledMailScriptDeclaresSinceHours() throws {
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
        #expect(ScriptReadWindow.arguments(for: today, lastRead: ago(hours: 30), now: Self.now)["since_hours"] as? Int == 31)
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

    private func tool(_ properties: [String: Any]?) -> ScriptTool {
        ScriptTool(id: "mail__today", packDir: "mail", fileName: "today.py", path: URL(fileURLWithPath: "/tmp/mail/scripts/today.py"),
                   description: "Fixture", inputSchema: properties.map { ["type": "object", "properties": $0] } ?? ["type": "object"],
                   dependencies: [])
    }

    private func mailJob() -> LearnedReadingSource {
        LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My personal inbox", application: "Mail",
                             scope: "Skip newsletters and promotions; show anything that needs a reply", script: "mail__today")
    }
}
