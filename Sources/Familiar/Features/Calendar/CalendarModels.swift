import CryptoKit
import Foundation

enum CalendarDataError: LocalizedError {
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): return message
        }
    }
}

/// The meaning learned from a demonstration, rather than a recording of fixed clicks.
struct LearnedCalendarSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var meaning: String = ""
    var application: String = ""
    var bundleID: String = ""
    var url: String = ""
    var account: String = ""
    var calendarName: String = ""
    var timeZoneID: String = ""
    var navigationHints: String = ""
    var completionChecks: String = ""
    var uncertainties: [String] = []
    var learnedAt: Date = Date()
    var workflowPath: String? = nil

    func validate() throws {
        for (value, label) in [(name, "name"), (meaning, "meaning")] {
            try calendarRequire(calendarHasText(value), "The calendar source needs its \(label).")
        }
        try calendarRequire([application, bundleID, url].contains(where: calendarHasText), "Identify the app or page containing this calendar.")
        try calendarRequire(timeZoneID.isEmpty || TimeZone(identifier: timeZoneID) != nil, "Choose a valid calendar time zone.")
        try calendarRequire(learnedAt.timeIntervalSince1970.isFinite, "The source learning time is invalid.")
    }
}

/// Source and day are snapshots so edits cannot silently redirect a running collection.
struct CalendarReadRequest: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: LearnedCalendarSource
    var day: Date
    var startHour: Int = 9
    var endHour: Int = 17

    var timeZoneID: String { source.timeZoneID }
    var calendar: Calendar { calendarInZone(timeZoneID) }
    var dayInterval: DateInterval { calendar.dateInterval(of: .day, for: day)! }
    var windowInterval: DateInterval { calendarWindow(day: day, calendar: calendar, startHour: startHour, endHour: endHour) }
    var dateLabel: String { calendarDateLabel(day, in: calendar) }

    func validate() throws {
        try source.validate()
        try calendarRequire(calendarHasText(source.account), "Confirm the account for this calendar before collecting it.")
        try calendarRequire(calendarHasText(source.calendarName), "Confirm which calendar to collect.")
        try validateCalendarWindow(day: day, timeZoneID: timeZoneID, startHour: startHour, endHour: endHour)
    }
}

enum CalendarEventResponse: String, Codable, CaseIterable {
    case accepted, declined, tentative, notResponded, organizer, unknown
}

enum CalendarEventAvailability: String, Codable, CaseIterable {
    case busy, free, tentative, unknown
}

struct CalendarEventRecord: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool = false
    var response: CalendarEventResponse = .unknown
    var availability: CalendarEventAvailability = .unknown
    var isCancelled: Bool = false
    var url: String = ""
    var evidence: String = ""
    var identityKey: String? = nil
    var identityEvidence: String? = nil
    var observedState: ObservedItemState? = nil
    var stateEvidence: String? = nil

    var interval: DateInterval { DateInterval(start: start, end: end) }
    var doesNotBlock: Bool { isCancelled || response == .declined || availability == .free }

    static func stableID(sourceID: UUID, title: String, start: Date, end: Date, allDay: Bool) -> String {
        // JSON framing avoids separator collisions; do not use Swift's per-process randomized Hasher.
        let components = [sourceID.uuidString, title.trimmingCharacters(in: .whitespacesAndNewlines),
                          String(start.timeIntervalSince1970), String(end.timeIntervalSince1970), String(allDay)]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return "derived-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CalendarCoverage: String, Codable, CaseIterable { case complete, partial }

struct CalendarSnapshot: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceID: UUID
    var day: Date
    var timeZoneID: String
    var startHour: Int = 9
    var endHour: Int = 17
    var events: [CalendarEventRecord]
    var coverage: CalendarCoverage
    var coverageNotes: [String] = []
    var accountEvidence: String
    var calendarEvidence: String
    var dateEvidence: String
    var collectedAt: Date = Date()
    /// The source accepted by this collection, retained even if its editable profile changes later.
    var source: LearnedCalendarSource? = nil

    var calendar: Calendar { calendarInZone(timeZoneID) }
    var dateLabel: String { calendarDateLabel(day, in: calendar) }
    var dayInterval: DateInterval { calendar.dateInterval(of: .day, for: day)! }
    var windowInterval: DateInterval { calendarWindow(day: day, calendar: calendar, startHour: startHour, endHour: endHour) }

    func validate() throws {
        try validateCalendarWindow(day: day, timeZoneID: timeZoneID, startHour: startHour, endHour: endHour)
        if let source {
            try source.validate()
            try calendarRequire(source.id == sourceID && source.timeZoneID == timeZoneID, "The saved collection does not match its original source identity.")
            try calendarRequire(calendarHasText(source.account) && calendarHasText(source.calendarName), "The original collection source needs its account and calendar.")
        }
        try calendarRequire(collectedAt.timeIntervalSince1970.isFinite, "The calendar collection time is invalid.")
        for (value, label) in [(accountEvidence, "account"), (calendarEvidence, "calendar"), (dateEvidence, "date")] {
            try calendarRequire(calendarHasText(value), "Record visible evidence of the requested \(label).")
        }
        if coverage == .partial {
            try calendarRequire(coverageNotes.contains(where: calendarHasText), "Describe what could not be collected.")
        }
        try calendarRequire(Set(events.map(\.id)).count == events.count, "The calendar collection contains duplicate event identifiers.")
        for event in events {
            try ObservedItemIdentity.validate(key: event.identityKey, identityEvidence: event.identityEvidence,
                state: event.observedState, stateEvidence: event.stateEvidence)
            try calendarRequire(calendarHasText(event.id) && calendarHasText(event.title) && calendarHasText(event.evidence), "Every calendar event needs an identifier, title, and visible evidence.")
            try calendarRequire(event.start.timeIntervalSince1970.isFinite && event.end.timeIntervalSince1970.isFinite && event.start < event.end, "Every calendar event must end after it starts.")
            try calendarRequire(event.start < dayInterval.end && event.end > dayInterval.start, "A collected event is outside the requested calendar day.")
            if event.allDay {
                try calendarRequire(calendar.startOfDay(for: event.start) == event.start && calendar.startOfDay(for: event.end) == event.end, "All-day events must use local midnight boundaries, with an exclusive end date.")
            }
        }
    }

    func matchesIdentity(of current: LearnedCalendarSource) -> Bool {
        guard let source else { return false }
        return source.id == current.id && source.application == current.application && source.bundleID == current.bundleID
            && source.url == current.url && source.account == current.account && source.calendarName == current.calendarName
            && source.timeZoneID == current.timeZoneID
    }
}

func calendarHasText(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

func calendarRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw CalendarDataError.invalid(message) }
}

func calendarInZone(_ identifier: String) -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
    return value
}

func calendarDateLabel(_ day: Date, in calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
}

func validateCalendarWindow(day: Date, timeZoneID: String, startHour: Int, endHour: Int) throws {
    try calendarRequire(day.timeIntervalSince1970.isFinite, "Choose a valid calendar day.")
    try calendarRequire(TimeZone(identifier: timeZoneID) != nil, "Choose a valid calendar time zone.")
    try calendarRequire(startHour >= 0 && startHour < endHour && endHour <= 24, "The calendar window must run from an earlier hour to a later hour between 0 and 24.")
    let calendar = calendarInZone(timeZoneID)
    try calendarRequire(calendar.dateInterval(of: .day, for: day) != nil, "Choose a supported calendar day.")
    try calendarRequire(calendarWindow(day: day, calendar: calendar, startHour: startHour, endHour: endHour).duration > 0, "The selected window has no elapsed time on this daylight-saving transition day.")
}

func calendarWindow(day: Date, calendar: Calendar, startHour: Int, endHour: Int) -> DateInterval {
    let interval = calendar.dateInterval(of: .day, for: day)!
    // Setting a wall-clock hour, rather than adding elapsed hours, handles DST days.
    func boundary(_ hour: Int) -> Date {
        if hour == 24 { return interval.end }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: interval.start,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)!
    }
    return DateInterval(start: boundary(startHour), end: boundary(endHour))
}
