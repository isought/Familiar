import Foundation

/// How far back a script job reads. A read goes back to the source's last read that a card step sorted, so mail from a
/// day the pack wasn't run, or from a read whose card step failed or was stopped, is still read, can land in the rest
/// and can be counted as a miss. The first read looks back the script's usual 24 hours. Reads twice a day overlap by
/// only an hour, and a message two reads both return counts once, on the day first read.
enum ScriptReadWindow {
    /// The script's default window, and the most it reads back (the mail script clamps `since_hours` to 1...168).
    static let defaultHours = 24, maximumHours = 168

    /// Whole hours since the last sorted read plus one, so mail that arrived while that read ran is read again, not
    /// lost. With no sorted read, or one the Mac's clock now puts in the future, it reads the usual 24 hours.
    static func hours(lastRead: Date?, now: Date) -> Int {
        guard let lastRead, lastRead <= now else { return defaultHours }
        return Int(min((now.timeIntervalSince(lastRead) / 3_600).rounded(.up) + 1, Double(maximumHours)))
    }

    /// When a card step last sorted the source's read: its newest findings in a run one of the step's receipts covers
    /// (`sorted`, their run IDs). A read no step sorted, because its step failed, was stopped or hasn't run yet, never
    /// moves the window. It comes from the card step's own receipts, not from the attention test, so deleting that
    /// test's folder, or a line it couldn't write, never shortens a read.
    static func lastRead(sourceID: UUID, runs: [SourceRunRecord], sorted: Set<UUID>) -> Date? {
        runs.filter { sorted.contains($0.id) }.flatMap(\.entries)
            .filter { $0.sourceID == sourceID && ($0.state == .complete || $0.state == .partial) }
            .compactMap { $0.readingSnapshot?.collectedAt }
            .max()
    }

    /// The script's arguments, each only for a script that declares it, since a script is called with exactly these
    /// and fails on one it doesn't take: `since_hours`, and `last_read`, when that read was, so the script can count
    /// what it leaves out past its limit that arrived after it, which no read returned. The limit and mailbox stay at
    /// the script's own defaults.
    static func arguments(for tool: ScriptTool, lastRead: Date?, now: Date) -> [String: Any] {
        let declared = tool.inputSchema["properties"] as? [String: Any] ?? [:]
        var arguments: [String: Any] = [:]
        if declared["since_hours"] != nil { arguments["since_hours"] = hours(lastRead: lastRead, now: now) }
        if declared["last_read"] != nil, let lastRead, lastRead <= now {
            arguments["last_read"] = ISO8601DateFormatter().string(from: lastRead)
        }
        return arguments
    }
}
