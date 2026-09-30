import Foundation

/// How far back a script job reads. A read goes back to the source's last read, so mail from a day the pack wasn't
/// run is still read, can land in the rest and can be counted as a miss. The first read, and any read within a day of
/// the last, looks back the script's usual 24 hours. A message two reads both return counts once, on the day first read.
enum ScriptReadWindow {
    /// The script's default window, and the most it reads back (the mail script clamps `since_hours` to 1...168).
    static let defaultHours = 24, maximumHours = 168

    /// Whole hours since the last read plus one, so mail that arrived while that read ran is read again, not lost.
    static func hours(lastRead: Date?, now: Date) -> Int {
        guard let lastRead else { return defaultHours }
        let hours = (now.timeIntervalSince(lastRead) / 3_600).rounded(.up) + 1
        return hours.isNaN ? defaultHours : Int(min(max(hours, Double(defaultHours)), Double(maximumHours)))
    }

    /// When the source's newest findings were collected. A failed, stopped or unfinished read saved none, so it
    /// leaves the window where the last read that did left it.
    static func lastRead(sourceID: UUID, runs: [SourceRunRecord]) -> Date? {
        runs.flatMap(\.entries)
            .filter { $0.sourceID == sourceID && ($0.state == .complete || $0.state == .partial) }
            .compactMap { $0.readingSnapshot?.collectedAt }
            .max()
    }

    /// The script's arguments: `since_hours` only for a script that declares it, since a script is called with
    /// exactly these and fails on one it doesn't take. The limit and mailbox stay at the script's own defaults.
    static func arguments(for tool: ScriptTool, lastRead: Date?, now: Date) -> [String: Any] {
        guard (tool.inputSchema["properties"] as? [String: Any])?["since_hours"] != nil else { return [:] }
        return ["since_hours": hours(lastRead: lastRead, now: now)]
    }
}
