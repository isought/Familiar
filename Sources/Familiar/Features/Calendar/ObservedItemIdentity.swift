import CryptoKit
import Foundation

/// Cross-run identity is based on source facts, never the mutable body of an observation.
enum ObservedItemIdentity {
    static let fieldNames: Set<String> = ["identityKey", "identityEvidence", "observedState", "stateEvidence"]
    static var schema: [String: Any] { [
        "identityKey": ["type": "string", "description": "Repeatable source item identity: prefer its visible native ID or permalink; otherwise stable sender/subject/original-date facts. Reuse a tracked item's exact key. Never use the current run/date, unread state, changing snippet, or a random ID."],
        "identityEvidence": ["type": "string", "description": "Visible facts supporting this identity and any match to a tracked item."],
        "observedState": ["type": "string", "enum": ObservedItemState.allCases.map(\.rawValue), "description": "resolved only with explicit current evidence that this item was replied to, closed, completed or cancelled. A read mark, absence, or changed snippet is not resolution. Otherwise open when visibly outstanding, unknown when not established."],
        "stateEvidence": ["type": "string", "description": "Current visible evidence supporting the state; required for open or resolved."],
    ] }

    static func id(sourceID: UUID, key: String) -> String {
        let bytes = (try? JSONEncoder().encode([sourceID.uuidString.lowercased(), key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])) ?? Data()
        return "identified-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func optionalText(_ input: [String: Any], _ key: String) throws -> String? {
        guard let value = input[key] else { return nil }
        guard let text = value as? String else { throw CalendarDataError.invalid("Observed \(key) must be text.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try calendarRequire(trimmed.count <= 20_000, "Observed \(key) is too long.")
        return trimmed.isEmpty ? nil : trimmed
    }

    static func state(_ input: [String: Any]) throws -> ObservedItemState? {
        guard let text = try optionalText(input, "observedState") else { return nil }
        guard let state = ObservedItemState(rawValue: text) else { throw CalendarDataError.invalid("Observed state must be open, resolved or unknown.") }
        return state
    }

    static func validate(key: String?, identityEvidence: String?, state: ObservedItemState?, stateEvidence: String?) throws {
        if key != nil {
            try calendarRequire(calendarHasText(key!) && calendarHasText(identityEvidence ?? ""), "A stable identity needs its visible supporting evidence.")
        }
        if state == .open || state == .resolved {
            try calendarRequire(calendarHasText(stateEvidence ?? ""), "An open or resolved observation needs current state evidence.")
        }
    }
}
