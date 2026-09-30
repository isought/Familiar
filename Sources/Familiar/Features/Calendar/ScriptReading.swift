import Foundation

/// A job that reads through a tools-folder script. The script's JSON becomes the run's findings directly, with no
/// model in between, so the counts are exact and everything that arrived is kept; the card step decides what matters.
///
/// The script returns `{account, server, mailbox, since, arrived, returned, truncated, items}` or `{error}`, and, when
/// told the last read, `cut_off_since_last_read`. Each item has a stable `key` and a `title`, plus either its own
/// `text` or the mail fields (`from`, `received`, `unread`, `starred`, `tab`, `important`, `bulk`, `preview`) that make one.
enum ScriptReading {
    @MainActor
    static func snapshot(from result: Any, request: ReadingReadRequest, collectedAt: Date = Date()) throws -> ReadingSnapshot {
        guard let result = result as? [String: Any] else {
            throw CalendarDataError.invalid("The script returned something Noteling can't read.")
        }
        if let error = result["error"] as? String { throw CalendarDataError.invalid(error) }
        let rows = result["items"] as? [[String: Any]] ?? []
        let account = text(result["account"]), server = text(result["server"])
        let mailbox = text(result["mailbox"]).isEmpty ? "the inbox" : text(result["mailbox"])
        let place = server.isEmpty ? mailbox : "\(mailbox) on \(server)"
        let since = (result["since"] as? String).flatMap(date).map(moment) ?? "the last check"
        let arrived = result["arrived"] as? Int ?? rows.count
        let truncated = result["truncated"] as? Bool ?? false

        var items: [ReadingItem] = []
        var seen: Set<String> = []
        for row in rows {
            let key = text(row["key"])
            let title = text(row["title"]).isEmpty ? "(no subject)" : text(row["title"])
            let identity = key.isEmpty ? nil : key
            let id = identity.map { ObservedItemIdentity.id(sourceID: request.source.id, key: $0) }
                ?? "script-\(request.id.uuidString.lowercased())-\(items.count)"
            guard seen.insert(id).inserted else { continue }   // one message delivered twice is one item
            let received = text(row["received"])
            items.append(ReadingItem(id: id, title: title, text: body(row),
                evidence: "Read through \(request.source.script ?? "a script") from \(place)" + (received.isEmpty ? "" : ", received \(received)"),
                url: readingHTTPURL(text(row["url"])) ? text(row["url"]) : "",
                identityKey: identity, identityEvidence: identity.map { "Message-ID \($0)" }, mail: MailFacts(row: row)))
        }
        let summary = arrived == 0 ? "Nothing arrived in \(mailbox) since \(since)."
            : truncated ? "Read the newest \(items.count) of \(arrived) messages that arrived in \(mailbox) since \(since)."
            : "Read all \(arrived) messages that arrived in \(mailbox) since \(since)."
        let snapshot = ReadingSnapshot(id: request.id, requestID: request.id, sourceID: request.source.id, source: request.source,
            collectedAt: collectedAt, items: items, coverage: truncated ? .partial : .complete,
            coverageNotes: truncated ? ["\(arrived) messages arrived; the newest \(items.count) are here."] : [],
            accountEvidence: account.isEmpty ? "The account the script is connected to" : "Signed in as \(account)",
            sourceEvidence: place, scopeEvidence: "Everything that arrived since \(since): \(arrived) message\(arrived == 1 ? "" : "s")",
            summary: summary, scriptRead: ScriptReadCounts(arrived: arrived, returned: result["returned"] as? Int ?? items.count,
                truncated: truncated, since: (result["since"] as? String).flatMap(date),
                cutOffSinceLastRead: result["cut_off_since_last_read"] as? Int))
        try snapshot.validate()
        return snapshot
    }

    /// The item's own text, or one line of mail facts followed by its preview.
    private static func body(_ row: [String: Any]) -> String {
        if !text(row["text"]).isEmpty { return text(row["text"]) }
        var facts: [String] = []
        if !text(row["from"]).isEmpty { facts.append("From \(text(row["from"]))") }
        if let when = date(text(row["received"])) { facts.append(moment(when)) }
        facts.append(row["unread"] as? Bool == false ? "read" : "unread")
        if row["starred"] as? Bool == true { facts.append("starred") }
        if !text(row["tab"]).isEmpty { facts.append("\(text(row["tab"]).capitalized) tab") }
        if row["important"] as? Bool == true { facts.append("marked important by Gmail") }
        if row["bulk"] as? Bool == true { facts.append("sent to a mailing list") }
        let preview = text(row["preview"])
        return facts.joined(separator: " · ") + (preview.isEmpty ? "" : "\n" + preview)
    }

    private static func text(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func moment(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
