import CoreFoundation
import Foundation

/// A collection is accepted only through this typed boundary. Model prose is never parsed as a schedule.
enum CalendarSubmission {
    static var schema: [String: Any] {
        let text: [String: Any] = ["type": "string"]
        let boolean: [String: Any] = ["type": "boolean"]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["sourceID", "day", "timeZoneID", "coverage", "coverageNotes", "accountEvidence", "calendarEvidence", "dateEvidence", "events"],
            "properties": [
                "sourceID": ["type": "string", "description": "The exact source UUID supplied in the collection request."],
                "day": ["type": "string", "description": "The exact requested local date, YYYY-MM-DD."],
                "timeZoneID": ["type": "string", "description": "The exact IANA time zone supplied in the request."],
                "coverage": ["type": "string", "enum": ["complete", "partial"], "description": "Complete only after verifying the requested account, calendar, date, all-day section, and every event across the entire day. Otherwise partial."],
                "coverageNotes": ["type": "array", "items": text, "description": "Visible checks supporting coverage, or specific gaps. Partial coverage requires at least one gap."],
                "accountEvidence": ["type": "string", "description": "Visible evidence identifying the requested account; do not merely repeat the request."],
                "calendarEvidence": ["type": "string", "description": "Visible evidence identifying the requested calendar."],
                "dateEvidence": ["type": "string", "description": "Visible evidence of the requested date and the displayed time zone."],
                "events": [
                    "type": "array", "items": [
                        "type": "object", "additionalProperties": false,
                        "required": ["title", "start", "end", "allDay", "response", "availability", "isCancelled", "evidence"],
                        "properties": ([
                            "id": ["type": "string", "description": "Stable identity from the source when visible. Omit when unavailable; Noteling derives a repeatable identity."],
                            "title": text,
                            "start": ["type": "string", "description": "ISO8601 date-time with explicit Z or ±HH:MM offset. All-day events start at local midnight."],
                            "end": ["type": "string", "description": "ISO8601 date-time with explicit Z or ±HH:MM offset; exclusive end, including the next local midnight for one-day all-day events."],
                            "allDay": boolean,
                            "response": ["type": "string", "enum": CalendarEventResponse.allCases.map(\.rawValue), "description": "Use unknown unless the RSVP state is visible."],
                            "availability": ["type": "string", "enum": CalendarEventAvailability.allCases.map(\.rawValue), "description": "Use unknown unless free/busy/tentative status is visible; a title alone is not evidence."],
                            "isCancelled": boolean,
                            "url": ["type": "string", "description": "Original event link if visible, otherwise omit or leave empty."],
                            "evidence": ["type": "string", "description": "Visible event text supporting title, times, response and availability; explicitly note fields not shown."]
                        ] as [String: Any]).merging(ObservedItemIdentity.schema) { _, value in value }
                    ]
                ]
            ]
        ]
    }

    static func parse(_ input: [String: Any], request: CalendarReadRequest) throws -> CalendarSnapshot {
        try request.validate()
        try requireKeys(input, allowed: ["sourceID", "day", "timeZoneID", "coverage", "coverageNotes", "accountEvidence", "calendarEvidence", "dateEvidence", "events"])
        let sourceID = try string(input, "sourceID")
        try calendarRequire(UUID(uuidString: sourceID) == request.source.id, "The submitted calendar source does not match this request.")
        try calendarRequire(try string(input, "day") == request.dateLabel, "The submitted day does not match the requested calendar day.")
        try calendarRequire(try string(input, "timeZoneID") == request.timeZoneID, "The submitted time zone does not match this calendar source.")
        guard let coverage = CalendarCoverage(rawValue: try string(input, "coverage")) else {
            throw CalendarDataError.invalid("Calendar coverage must be complete or partial.")
        }
        guard let notes = input["coverageNotes"] as? [String], let rows = input["events"] as? [[String: Any]] else {
            throw CalendarDataError.invalid("Calendar coverage notes and events must be arrays.")
        }
        var events: [CalendarEventRecord] = []
        var seen: [String: CalendarEventRecord] = [:]
        for row in rows {
            try requireKeys(row, allowed: Set(["id", "title", "start", "end", "allDay", "response", "availability", "isCancelled", "url", "evidence"]).union(ObservedItemIdentity.fieldNames))
            let title = try string(row, "title")
            let start = try timestamp(string(row, "start"))
            let end = try timestamp(string(row, "end"))
            let allDay = try boolean(row, "allDay")
            guard let response = CalendarEventResponse(rawValue: try string(row, "response")),
                  let availability = CalendarEventAvailability(rawValue: try string(row, "availability")) else {
                throw CalendarDataError.invalid("An event has an unsupported response or availability value.")
            }
            let submittedID = try optionalString(row, "id")
            let identityKey = try ObservedItemIdentity.optionalText(row, "identityKey")
            let id = identityKey.map { ObservedItemIdentity.id(sourceID: request.source.id, key: $0) }
                ?? (calendarHasText(submittedID) ? submittedID : CalendarEventRecord.stableID(sourceID: request.source.id, title: title, start: start, end: end, allDay: allDay))
            let cancelled = try boolean(row, "isCancelled")
            let state = try ObservedItemIdentity.state(row)
            let evidence = try string(row, "evidence")
            let stateEvidence = try ObservedItemIdentity.optionalText(row, "stateEvidence")
            let event = CalendarEventRecord(id: id, title: title, start: start, end: end, allDay: allDay,
                                            response: response, availability: availability,
                                            isCancelled: cancelled,
                                            url: try optionalString(row, "url"), evidence: evidence,
                                            identityKey: identityKey, identityEvidence: try ObservedItemIdentity.optionalText(row, "identityEvidence"),
                                            observedState: cancelled ? .resolved : state,
                                            stateEvidence: cancelled ? (stateEvidence ?? evidence) : stateEvidence)
            if let existing = seen[id] {
                try calendarRequire(existing == event, "The same calendar event was submitted with conflicting details. Verify it before saving.")
                continue
            }
            seen[id] = event
            events.append(event)
        }
        let result = CalendarSnapshot(id: request.id, sourceID: request.source.id,
                                      day: request.dayInterval.start, timeZoneID: request.timeZoneID,
                                      startHour: request.startHour, endHour: request.endHour,
                                      events: events.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) },
                                      coverage: coverage, coverageNotes: notes,
                                      accountEvidence: try string(input, "accountEvidence"),
                                      calendarEvidence: try string(input, "calendarEvidence"),
                                      dateEvidence: try string(input, "dateEvidence"), source: request.source)
        try result.validate()
        return result
    }

    private static func requireKeys(_ input: [String: Any], allowed: Set<String>) throws {
        try calendarRequire(Set(input.keys).isSubset(of: allowed), "The calendar submission contains unsupported fields.")
    }

    private static func string(_ input: [String: Any], _ key: String) throws -> String {
        guard let value = input[key] as? String, calendarHasText(value) else {
            throw CalendarDataError.invalid("The calendar submission needs a nonempty \(key).")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalString(_ input: [String: Any], _ key: String) throws -> String {
        guard input[key] != nil else { return "" }
        guard let value = input[key] as? String else { throw CalendarDataError.invalid("Calendar \(key) must be text.") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boolean(_ input: [String: Any], _ key: String) throws -> Bool {
        guard let value = input[key], CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else {
            throw CalendarDataError.invalid("Calendar \(key) must be true or false.")
        }
        return flag
    }

    /// Parse strictly: Foundation's component construction can otherwise normalize invalid dates.
    static func timestamp(_ value: String) throws -> Date {
        let expression = try NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            throw CalendarDataError.invalid("Calendar timestamps must be ISO8601 with an explicit time-zone offset.")
        }
        func part(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
        let year = Int(part(1))!, month = Int(part(2))!, day = Int(part(3))!
        let hour = Int(part(4))!, minute = Int(part(5))!, second = Int(part(6))!
        let zone = part(8)
        var offset = 0
        if zone != "Z" {
            let pieces = zone.dropFirst().split(separator: ":")
            let hours = Int(pieces[0])!, minutes = Int(pieces[1])!
            try calendarRequire(hours <= 23 && minutes < 60, "The event timestamp has an invalid time-zone offset.")
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        try calendarRequire(year > 0 && month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour < 24 && minute < 60 && second < 60, "The event timestamp is invalid.")
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { throw CalendarDataError.invalid("The event timestamp has an invalid offset.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else {
            throw CalendarDataError.invalid("The event timestamp contains an invalid calendar date.")
        }
        return date.addingTimeInterval(Double("0." + part(7)) ?? 0)
    }
}
