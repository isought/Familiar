import Foundation

enum SourceRunOrigin: String, Codable { case single, all, migration }
enum SourceRunStatus: String, Codable { case running, completed, stopped, failed, interrupted }

/// An immutable request profile and the observation made during this particular run.
struct SourceRunEntry: Codable, Equatable, Identifiable {
    enum State: String, Codable { case waiting, reading, complete, partial, failed, stopped, notRun, interrupted }
    var id: UUID
    var calendarRequest: CalendarReadRequest?
    var readingSource: LearnedReadingSource?
    var requestedAt: Date
    var state: State = .waiting
    var message = ""
    var startedAt: Date?
    var finishedAt: Date?
    var calendarSnapshot: CalendarSnapshot?
    var readingSnapshot: ReadingSnapshot?

    init(calendar: CalendarReadRequest, state: State = .waiting, message: String = "") {
        id = calendar.id; calendarRequest = calendar; requestedAt = Date()
        self.state = state; self.message = message
    }
    init(reading: ReadingReadRequest, state: State = .waiting, message: String = "") {
        id = reading.id; readingSource = reading.source; requestedAt = reading.requestedAt
        self.state = state; self.message = message
    }

    var sourceID: UUID { calendarRequest?.source.id ?? readingSource!.id }
    var sourceName: String { calendarRequest?.source.name ?? readingSource?.name ?? "Unknown source" }
    var dateLabel: String {
        guard let request = calendarRequest else { return "Current information" }
        return request.day.timeIntervalSinceReferenceDate.isFinite && request.calendar.dateInterval(of: .day, for: request.day) != nil ? request.dateLabel : "Unknown day"
    }

    func validate() throws {
        try calendarRequire((calendarRequest != nil) != (readingSource != nil), "A run entry must capture exactly one source.")
        try calendarRequire(requestedAt.timeIntervalSinceReferenceDate.isFinite, "The run request time is invalid.")
        for date in [startedAt, finishedAt].compactMap({ $0 }) {
            try calendarRequire(date.timeIntervalSinceReferenceDate.isFinite, "A run entry time is invalid.")
        }
        if let request = calendarRequest {
            try request.source.validate()
            try calendarRequire(id == request.id && request.day.timeIntervalSinceReferenceDate.isFinite, "The archived calendar request is invalid.")
            try calendarRequire(readingSnapshot == nil, "A calendar run contains unrelated reading results.")
            if let snapshot = calendarSnapshot {
                try snapshot.validate()
                try calendarRequire(snapshot.sourceID == sourceID && snapshot.dateLabel == request.dateLabel
                    && snapshot.timeZoneID == request.source.timeZoneID && snapshot.startHour == request.startHour && snapshot.endHour == request.endHour,
                    "The calendar result does not match its captured request.")
                if let source = snapshot.source {
                    try calendarRequire(source == request.source, "The calendar result has different captured rules.")
                }
            }
        }
        if let source = readingSource {
            try source.validate()
            try calendarRequire(calendarSnapshot == nil, "A reading run contains unrelated calendar results.")
            if let snapshot = readingSnapshot {
                try snapshot.validate()
                try calendarRequire(snapshot.source == source && snapshot.requestID == id, "The reading result does not match its captured request.")
            }
        }
        let coverage = calendarSnapshot?.coverage ?? readingSnapshot?.coverage
        if state == .complete || state == .partial {
            try calendarRequire(coverage != nil && (state == .complete ? coverage == .complete : coverage == .partial), "A successful run entry needs its matching collected result.")
        } else {
            try calendarRequire(coverage == nil, "An unfinished or unsuccessful entry cannot publish collected results.")
        }
    }
}

struct SourceRunRecord: Codable, Equatable, Identifiable {
    var version = 1
    var id = UUID()
    var origin: SourceRunOrigin
    var startedAt: Date
    var finishedAt: Date?
    var timeZoneID: String
    var status: SourceRunStatus = .running
    var entries: [SourceRunEntry]

    func validate() throws {
        try calendarRequire(version == 1, "This run archive version is not supported.")
        try calendarRequire(startedAt.timeIntervalSinceReferenceDate.isFinite && (finishedAt?.timeIntervalSinceReferenceDate.isFinite ?? true), "The run time is invalid.")
        try calendarRequire(TimeZone(identifier: timeZoneID) != nil, "The run time zone is invalid.")
        try calendarRequire(!entries.isEmpty && Set(entries.map(\.id)).count == entries.count, "A run needs uniquely identified source requests.")
        for entry in entries { try entry.validate() }
        try calendarRequire(Set(entries.map(\.sourceID)).count == entries.count, "A run cannot contain the same source twice.")
        if status != .running {
            try calendarRequire(finishedAt != nil && entries.allSatisfy { $0.state != .waiting && $0.state != .reading }, "A finished run contains unfinished requests.")
        } else {
            try calendarRequire(finishedAt == nil, "A running collection has a finish time.")
        }
    }
}

/// Explicit UTC offsets and nanoseconds keep exported dates readable without losing Date precision.
enum SourceRunJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(timestamp(date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try CalendarSubmission.timestamp(value)
        }
        return decoder
    }
    static func timestamp(_ date: Date) -> String {
        let reference = date.timeIntervalSinceReferenceDate
        var seconds = floor(reference)
        var nanoseconds = Int(((reference - seconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 { seconds += 1; nanoseconds = 0 }
        let formatter = ISO8601DateFormatter()
        let whole = formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds)).dropLast()
        return "\(whole).\(String(format: "%09d", nanoseconds))Z"
    }
}
