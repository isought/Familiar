import CryptoKit
import Foundation

/// A learned view to read again. This profile is reference material, never a script to execute.
struct LearnedReadingSource: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case mail, web }
    var id = UUID()
    var kind: Kind = .web
    var name = ""
    var meaning = ""
    var application = ""
    var bundleID = ""
    var url = ""
    var account = ""
    var scope = ""
    var navigationHints = ""
    var completionChecks = ""
    var uncertainties: [String] = []
    var learnedAt = Date()
    var requiresReview = false
    var workflowPath = ""
    /// A tools-folder script this job reads through (`pack__script`), instead of a window it was taught.
    var script: String? = nil

    var readsThroughScript: Bool { calendarHasText(script ?? "") }

    func validate() throws {
        try calendarRequire(calendarHasText(name) && calendarHasText(meaning), "Give the reading source a name and meaning.")
        try calendarRequire(!url.isEmpty || !bundleID.isEmpty || readsThroughScript,
                            "Identify the source with its page address, native app identifier or a script that reads it.")
        try calendarRequire(url.isEmpty || readingHTTPURL(url), "Use a full http or https source address.")
        try calendarRequire(learnedAt.timeIntervalSince1970.isFinite, "The source learning time is invalid.")
    }

    /// No account is needed: without one, a run reads the account its taught view shows and records it. A wrong
    /// guess only costs a read the person can see, so it never waits on them to type one in.
    func validateForRead() throws {
        try validate()
        try calendarRequire(!requiresReview, "Review and save this source’s location and reading scope before running it.")
        try calendarRequire(calendarHasText(scope), "Its reading rules are empty, so it doesn't know what to read (for example, “today's unread messages”).")
    }

    /// What stops this source from running as saved, apart from a pending review; nil when it's ready.
    var missingSetup: String? {
        var reviewed = self
        reviewed.requiresReview = false
        do { try reviewed.validateForRead(); return nil } catch { return error.localizedDescription }
    }

    func matchesIdentity(of other: Self) -> Bool {
        id == other.id && kind == other.kind && application == other.application && bundleID == other.bundleID
            && url == other.url && account == other.account && scope == other.scope && script == other.script
    }
}

struct ReadingReadRequest: Identifiable, Equatable {
    var id = UUID()
    var source: LearnedReadingSource
    var requestedAt = Date()
    var dateLabel: String { "Current saved scope" }

    func validate() throws {
        try source.validateForRead()
        try calendarRequire(requestedAt.timeIntervalSince1970.isFinite, "The collection request time is invalid.")
    }
}

struct ReadingItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var text: String
    var evidence: String
    var url = ""
    var identityKey: String? = nil
    var identityEvidence: String? = nil
    var observedState: ObservedItemState? = nil
    var stateEvidence: String? = nil
}

struct ReadingSnapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var requestID: UUID
    var sourceID: UUID
    var source: LearnedReadingSource
    var collectedAt = Date()
    var items: [ReadingItem]
    var coverage: CalendarCoverage
    var coverageNotes: [String] = []
    var accountEvidence: String
    var sourceEvidence: String
    var scopeEvidence: String
    /// The reader's one line for the person: what it read and what it assumed or couldn't check.
    var summary: String? = nil
    /// A script job keeps everything that arrived; the card step picks what matters.
    static let scriptItemLimit = 500

    /// What this read assumed, so the person can say what's wrong: the reader's summary, else the account it saw
    /// and, for a partial read, what it couldn't check (a complete read's notes say what it verified).
    var assumptions: String {
        if let summary, calendarHasText(summary) { return summary }
        let gaps = coverage == .partial && !coverageNotes.isEmpty ? " Couldn't check: " + coverageNotes.joined(separator: "; ") : ""
        return "Account seen: \(accountEvidence)." + gaps
    }

    func validate() throws {
        try source.validateForRead()
        try calendarRequire(source.id == sourceID, "The reading collection has a different source identity.")
        try calendarRequire(collectedAt.timeIntervalSince1970.isFinite, "The collection time is invalid.")
        let limit = source.readsThroughScript ? Self.scriptItemLimit : ReadingSubmission.maximumItemLimit
        try calendarRequire(items.count <= limit, "A collection can contain at most \(limit) observations including tracked follow-ups. Report remaining coverage as partial.")
        try calendarRequire(Set(items.map(\.id)).count == items.count, "Reading observations contain duplicate identifiers.")
        for item in items {
            try calendarRequire([item.id, item.title, item.text, item.evidence].allSatisfy(calendarHasText), "Each reading observation needs its title, text and visible evidence.")
            try calendarRequire(item.url.isEmpty || readingHTTPURL(item.url), "An observation link must be http or https.")
            try ObservedItemIdentity.validate(key: item.identityKey, identityEvidence: item.identityEvidence,
                state: item.observedState, stateEvidence: item.stateEvidence)
        }
        try calendarRequire([accountEvidence, sourceEvidence, scopeEvidence].allSatisfy(calendarHasText), "A collection needs account, source and scope evidence from the current view.")
        try calendarRequire(coverageNotes.allSatisfy(calendarHasText), "Coverage notes must contain text.")
        try calendarRequire(coverage != .partial || !coverageNotes.isEmpty, "A partial collection must explain its gaps.")
    }
}

func readingHTTPURL(_ text: String) -> Bool {
    guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
    return true
}

enum ReadingSubmission {
    static let itemLimit = 25
    static let trackedItemLimit = 10
    static let maximumItemLimit = itemLimit + trackedItemLimit
    static var schema: [String: Any] { schema(trackedItemCount: 0) }
    static func schema(trackedItemCount: Int) -> [String: Any] {
        let text: [String: Any] = ["type": "string"]
        return ["type": "object", "additionalProperties": false,
                "required": ["sourceID", "requestID", "coverage", "coverageNotes", "accountEvidence", "sourceEvidence", "scopeEvidence", "items"],
                "properties": [
                    "sourceID": text, "requestID": text,
                    "coverage": ["type": "string", "enum": ["complete", "partial"], "description": "Complete only for the exact saved scope verified in the live view. A viewport or 25-item limit does not establish a complete mailbox."],
                    "coverageNotes": ["type": "array", "items": text],
                    "accountEvidence": text, "sourceEvidence": text, "scopeEvidence": text,
                    "summary": ["type": "string", "description": "One plain sentence for the person: what you read and what you assumed or couldn't check."],
                    "items": ["type": "array", "maxItems": itemLimit + min(trackedItemLimit, max(0, trackedItemCount)), "items": [
                        "type": "object", "additionalProperties": false, "required": ["title", "text", "evidence"],
                        "properties": (["id": text, "title": text, "text": ["type": "string", "description": "Observed information only. For mail include visible sender, subject/snippet, and timestamp as shown; do not invent full bodies or exact dates."],
                                       "evidence": text, "url": text] as [String: Any]).merging(ObservedItemIdentity.schema) { _, value in value }]]
                ]]
    }

    static func parse(_ input: [String: Any], request: ReadingReadRequest, trackedItems: [TrackedSourceItem] = []) throws -> ReadingSnapshot {
        try request.validate()
        try keys(input, allowed: ["sourceID", "requestID", "coverage", "coverageNotes", "accountEvidence", "sourceEvidence", "scopeEvidence", "summary", "items"])
        try calendarRequire(UUID(uuidString: try string(input, "sourceID")) == request.source.id, "The reading source does not match this request.")
        try calendarRequire(UUID(uuidString: try string(input, "requestID")) == request.id, "The reading collection belongs to a different request. Read freshly for this run.")
        guard var coverage = CalendarCoverage(rawValue: try string(input, "coverage")),
              var notes = input["coverageNotes"] as? [String], let rows = input["items"] as? [[String: Any]] else {
            throw CalendarDataError.invalid("Supply complete/partial coverage, coverage notes, and an array of observations.")
        }
        let trackedKeys = Set(trackedItems.prefix(trackedItemLimit).map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        try calendarRequire(rows.count <= itemLimit + trackedKeys.count, "Collect at most \(itemLimit) new observations plus the explicitly tracked follow-ups, and report remaining coverage as partial.")
        var items: [ReadingItem] = []
        var seen: [String: ReadingItem] = [:]
        for row in rows {
            try keys(row, allowed: Set(["id", "title", "text", "evidence", "url"]).union(ObservedItemIdentity.fieldNames))
            let title = try string(row, "title"), text = try string(row, "text"), evidence = try string(row, "evidence")
            let url = try optional(row, "url"), suppliedID = try optional(row, "id")
            let bytes = try JSONSerialization.data(withJSONObject: [request.source.id.uuidString, title, text, url])
            let identityKey = try ObservedItemIdentity.optionalText(row, "identityKey")
            let id = identityKey.map { ObservedItemIdentity.id(sourceID: request.source.id, key: $0) }
                ?? (calendarHasText(suppliedID) ? suppliedID : "observed-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let item = ReadingItem(id: id, title: title, text: text, evidence: evidence, url: url,
                identityKey: identityKey, identityEvidence: try ObservedItemIdentity.optionalText(row, "identityEvidence"),
                observedState: try ObservedItemIdentity.state(row), stateEvidence: try ObservedItemIdentity.optionalText(row, "stateEvidence"))
            if let previous = seen[id] {
                try calendarRequire(previous == item, "The same observation has conflicting details. Check the current view.")
            } else { seen[id] = item; items.append(item) }
        }
        let newItems = items.filter { !trackedKeys.contains(($0.identityKey ?? $0.id).lowercased()) }
        try calendarRequire(newItems.count <= itemLimit, "Additional observations must match the explicitly tracked item keys.")
        let observedKeys = Set(items.map { ($0.identityKey ?? $0.id).lowercased() })
        let missing = trackedItems.prefix(trackedItemLimit).filter { !observedKeys.contains($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        if !missing.isEmpty {
            coverage = .partial
            notes.append("Tracked follow-ups not verified in this collection: " + missing.map(\.title).joined(separator: "; ") + ". Their status remains unresolved.")
        }
        let snapshot = ReadingSnapshot(id: request.id, requestID: request.id, sourceID: request.source.id, source: request.source,
            items: items, coverage: coverage, coverageNotes: notes,
            accountEvidence: try string(input, "accountEvidence"), sourceEvidence: try string(input, "sourceEvidence"),
            scopeEvidence: try string(input, "scopeEvidence"), summary: summary(try optional(input, "summary")))
        try snapshot.validate()
        return snapshot
    }

    private static func summary(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 400 ? String(line.prefix(399)) + "…" : line
    }
    private static func keys(_ input: [String: Any], allowed: Set<String>) throws {
        try calendarRequire(Set(input.keys).isSubset(of: allowed), "The reading submission contains unsupported fields.")
    }
    private static func string(_ input: [String: Any], _ key: String) throws -> String {
        let value = try optional(input, key)
        try calendarRequire(calendarHasText(value), "The reading submission needs a nonempty \(key).")
        return value
    }
    private static func optional(_ input: [String: Any], _ key: String) throws -> String {
        guard let value = input[key] else { return "" }
        guard let text = value as? String else { throw CalendarDataError.invalid("Reading \(key) must be text.") }
        try calendarRequire(text.count <= 20_000, "Reading \(key) is too long. Keep only the relevant observed information.")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReadingBriefing {
    static func render(_ snapshot: ReadingSnapshot) -> String {
        guard (try? snapshot.validate()) != nil else { return "This collection is invalid. Read the source again." }
        var lines = [snapshot.source.name,
                     snapshot.coverage == .complete ? "Complete · \(snapshot.items.count) \(snapshot.items.count == 1 ? "item" : "items") collected." : "Partial read — some of the saved scope could not be checked."]
        if let summary = snapshot.summary { lines.append(summary) }
        if snapshot.items.isEmpty {
            lines.append(snapshot.coverage == .complete ? "No items were visible in the verified scope." : "No items were collected; this does not establish an empty source.")
        } else {
            for item in snapshot.items { lines.append("\n• \(item.title)\n\(item.text)") }
        }
        lines.append("\nCollection details")
        lines.append("Account: \(snapshot.accountEvidence)")
        if snapshot.source.account.isEmpty { lines.append("No account identity was saved during teaching. This result describes the account visibly open at the saved location.") }
        if !snapshot.coverageNotes.isEmpty {
            lines.append(contentsOf: snapshot.coverageNotes.map { "• " + $0 })
        }
        return lines.joined(separator: "\n")
    }
}
