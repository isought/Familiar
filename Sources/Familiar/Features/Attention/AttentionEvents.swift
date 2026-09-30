import Foundation

/// One line of the attention ledger: what a card step read and showed, and what the person did about it, kept
/// on this Mac only. Each line is one flat JSON object, the envelope's keys beside the payload's, and every line
/// says which schema wrote it so a newer one can be skipped rather than misread.
struct AttentionEvent: Equatable, Identifiable {
    static let schema = 1
    /// The version that wrote a line; a build run straight from `swift build` says "dev".
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    let id: UUID
    /// Kept to the millisecond, as the file keeps it.
    let at: Date
    /// The local day of `at`, "yyyy-MM-dd", in `timeZone`.
    let day: String
    let timeZone: TimeZone
    let app: String
    let payload: Payload
    var type: AttentionEventType { payload.type }

    /// Times are kept to the millisecond, so an event reads back equal to the one appended.
    init(_ payload: Payload, at: Date = Date(), timeZone: TimeZone = .current, id: UUID = UUID(), app: String = AttentionEvent.appVersion) {
        self.id = id
        self.at = AttentionTime.toTheMillisecond(at)
        self.timeZone = TimeZone(identifier: timeZone.identifier) ?? timeZone
        day = AttentionTime.day(of: self.at, in: self.timeZone)
        self.app = app
        self.payload = payload.toTheMillisecond
    }

    enum Payload: Equatable {
        /// Written once, when the file is created.
        case started
        case sorted(Sorted)
        case label(Label)
        case implicit(Implicit)
        case miss(Miss)
        case opened(Opened)
        case restViewed(RestViewed)
        case engaged(Engaged)
    }

    /// What one card step read from script sources and which of those items it showed as cards. A message is written in
    /// full by the first line that reads it; a later read lists it in `seen` by its key alone, so a window read twice a
    /// day does not write the same mail twice.
    struct Sorted: Codable, Equatable {
        var runIDs: [UUID]
        var backfilled: Bool
        var sources: [Source]
        /// Messages no earlier line read, in full.
        var items: [AttentionItem]
        /// Messages an earlier line already holds, read again. Nil when there were none, and in lines from before it.
        var seen: [Seen]? = nil
        /// Mail jobs the same step read from the screen, not through a script. A card from one can show a message the
        /// script also read, which then counts as left out, so the screens say when one ran. Nil when none did, and in
        /// lines from before it.
        var screenRead: [ScreenRead]? = nil

        /// A message read again: its key, and whether this step showed it.
        struct Seen: Codable, Equatable {
            var key: String
            var shown: Bool
        }

        /// A mail job read from the screen, by its id and name only: nothing it read is kept.
        struct ScreenRead: Codable, Equatable {
            var sourceID: UUID
            var sourceName: String
        }

        /// One script read in the step, including a read that found nothing.
        struct Source: Codable, Equatable {
            var sourceID: UUID
            var sourceName: String
            var script: String
            var runID: UUID
            var collectedAt: Date
            var since: Date?
            var arrived: Int
            var returned: Int
            var truncated: Bool
            /// The script's own count of what it cut off that arrived after the last sorted read: `ScriptReadCounts`.
            var cutOffSinceLastRead: Int? = nil
        }
    }

    /// A thumb, a clear or an explanation the person gave. `prior` is the label in effect when it was given.
    struct Label: Codable, Equatable {
        var key: String
        var value: AttentionLabelValue
        var weight: Int
        var prior: AttentionPrior
        var text: String?
        var via: AttentionVia
        var item: AttentionItem
        /// Nil for an item that never had a card, or whose card is gone.
        var card: AttentionCardContext?
    }

    /// Something the person already did to a card that says whether it was worth showing.
    struct Implicit: Codable, Equatable {
        var key: String
        var signal: AttentionSignal
        /// For a retract, the signal it takes back.
        var retracts: AttentionSignal?
        /// For a tapped option, its place among the card's options before the tap.
        var optionIndex: Int?
        var optionMode: MorningActionMode?
        var item: AttentionItem
        var card: AttentionCardContext
    }

    /// "Should have shown me" on an item that was not shown, or taking that back.
    struct Miss: Codable, Equatable {
        var key: String
        var retract: Bool
        var item: AttentionItem
    }

    /// The pack opened. `route` is a short name for the screen it opened on; `desk` counts the cards to review.
    struct Opened: Codable, Equatable {
        var trigger: AttentionOpenTrigger
        var route: String
        var desk: Int
    }

    /// The rest of `restDay` was on screen. `restDay` is the day read, which can be earlier than the event's own day.
    struct RestViewed: Codable, Equatable {
        var restDay: String
        var count: Int
        var reachedEnd: Bool
        var seconds: Double
    }

    /// Looking at a card, which is neither a yes nor a no.
    struct Engaged: Codable, Equatable {
        var key: String
        var what: AttentionEngagement
        var card: AttentionCardContext
    }
}

enum AttentionEventType: String, Codable, CaseIterable {
    case started, sorted, label, implicit, miss, opened, restViewed = "rest_viewed", engaged
}

enum AttentionLabelValue: String, Codable, CaseIterable {
    case yes, no, strongYes = "strong_yes", strongNo = "strong_no", explain, clear
}

/// The label in effect before a new one: given by the person, guessed from what they did, or none.
enum AttentionPrior: String, Codable, CaseIterable {
    case yes, no, strongYes = "strong_yes", strongNo = "strong_no", guessYes = "guess_yes", guessNo = "guess_no", notSet = "none"
}

enum AttentionSignal: String, Codable, CaseIterable {
    case optionTapped = "option_tapped", contextRequested = "context_requested", mine, ignored, handled, adjusted, retract
}

enum AttentionOpenTrigger: String, Codable, CaseIterable {
    case launcher, menu, taskPanel = "task_panel", chat, people, run
}

/// Where a label was given: on the card, in the rest screen's shown list, or on a row of the rest.
enum AttentionVia: String, Codable, CaseIterable { case card, shown, rest }

enum AttentionEngagement: String, Codable, CaseIterable { case cardOpened = "card_opened" }

/// One item a card step read, with the facts a later filter could learn from. Written in full by the `sorted` line that
/// first read it and copied into every other event about it, so the ledger stands on its own after runs and cards are
/// deleted. Mail fields are nil when the read had none. At its longest an item is about 1.25 KB of JSON, so a `sorted`
/// line of 200 new messages is about 250 KB.
struct AttentionItem: Codable, Equatable {
    static let previewLimit = 280

    var key: String
    var sourceID: UUID
    var sourceName: String
    var kind: String
    var script: String?
    var runID: UUID
    var itemID: String
    var readAt: Date
    var subject: String
    var from: String?
    var fromName: String?
    var address: String?
    var domain: String?
    var tab: String?
    var bulk: Bool?
    var important: Bool?
    var starred: Bool?
    var unread: Bool?
    var received: Date?
    /// Local hour, 0-23.
    var receivedHour: Int?
    /// Local weekday as Calendar counts it: 1 is Sunday.
    var receivedWeekday: Int?
    var ageHours: Double?
    var preview: String
    var url: String?
    var shown: Bool
}

/// The card as it stood when the event happened.
struct AttentionCardContext: Codable, Equatable {
    var cardID: UUID
    var disposition: MorningCardDisposition
    var displayDisposition: MorningCardDisposition
    var optionCount: Int
    var optionModes: [MorningActionMode]
    var cardAgeHours: Double
    var userEdited: Bool
    var hasPersonalContext: Bool
    var createdByRun: UUID?
}

// MARK: - One line of JSON

extension AttentionEvent: Codable {
    private enum Envelope: String, CodingKey { case schema, id, type, at, day, tz, app }

    /// One line without its newline: sorted keys, and every time in the event's own zone.
    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let formatter = AttentionTime.formatter(in: timeZone)   // one for the line, not one for each of its times
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        return try encoder.encode(self)
    }

    /// Throws for a torn line, a newer schema or an unknown type, so a reader can skip it.
    init(line: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            guard let date = AttentionTime.date(try value.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "An attention time must be ISO-8601.")
            }
            return date
        }
        self = try decoder.decode(AttentionEvent.self, from: line)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Envelope.self)
        guard try values.decode(Int.self, forKey: .schema) == Self.schema else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: values, debugDescription: "Written by a newer schema.")
        }
        let type = try values.decode(AttentionEventType.self, forKey: .type)
        let zone = try values.decode(String.self, forKey: .tz)
        guard let timeZone = TimeZone(identifier: zone) else {
            throw DecodingError.dataCorruptedError(forKey: .tz, in: values, debugDescription: "Unknown time zone \(zone).")
        }
        id = try values.decode(UUID.self, forKey: .id)
        at = try values.decode(Date.self, forKey: .at)
        day = try values.decode(String.self, forKey: .day)
        self.timeZone = timeZone
        app = try values.decode(String.self, forKey: .app)
        switch type {
        case .started: payload = .started
        case .sorted: payload = .sorted(try Sorted(from: decoder))
        case .label: payload = .label(try Label(from: decoder))
        case .implicit: payload = .implicit(try Implicit(from: decoder))
        case .miss: payload = .miss(try Miss(from: decoder))
        case .opened: payload = .opened(try Opened(from: decoder))
        case .restViewed: payload = .restViewed(try RestViewed(from: decoder))
        case .engaged: payload = .engaged(try Engaged(from: decoder))
        }
    }

    /// The payload's keys go into the same object as the envelope's, so no payload may use an envelope key: it
    /// would silently replace the envelope's value. The schema test checks this.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Envelope.self)
        try values.encode(Self.schema, forKey: .schema)
        try values.encode(id, forKey: .id)
        try values.encode(type, forKey: .type)
        try values.encode(at, forKey: .at)
        try values.encode(day, forKey: .day)
        try values.encode(timeZone.identifier, forKey: .tz)
        try values.encode(app, forKey: .app)
        switch payload {
        case .started: break
        case .sorted(let value): try value.encode(to: encoder)
        case .label(let value): try value.encode(to: encoder)
        case .implicit(let value): try value.encode(to: encoder)
        case .miss(let value): try value.encode(to: encoder)
        case .opened(let value): try value.encode(to: encoder)
        case .restViewed(let value): try value.encode(to: encoder)
        case .engaged(let value): try value.encode(to: encoder)
        }
    }
}

extension AttentionEvent.Payload {
    var type: AttentionEventType {
        switch self {
        case .started: return .started
        case .sorted: return .sorted
        case .label: return .label
        case .implicit: return .implicit
        case .miss: return .miss
        case .opened: return .opened
        case .restViewed: return .restViewed
        case .engaged: return .engaged
        }
    }

    fileprivate var toTheMillisecond: Self {
        switch self {
        case .sorted(var sorted):
            for index in sorted.sources.indices {
                sorted.sources[index].collectedAt = AttentionTime.toTheMillisecond(sorted.sources[index].collectedAt)
                sorted.sources[index].since = sorted.sources[index].since.map(AttentionTime.toTheMillisecond)
            }
            sorted.items = sorted.items.map(\.toTheMillisecond)
            return .sorted(sorted)
        case .label(var label): label.item = label.item.toTheMillisecond; return .label(label)
        case .implicit(var signal): signal.item = signal.item.toTheMillisecond; return .implicit(signal)
        case .miss(var miss): miss.item = miss.item.toTheMillisecond; return .miss(miss)
        case .started, .opened, .restViewed, .engaged: return self
        }
    }
}

private extension AttentionItem {
    var toTheMillisecond: Self {
        var item = self
        item.readAt = AttentionTime.toTheMillisecond(readAt)
        item.received = received.map(AttentionTime.toTheMillisecond)
        return item
    }
}

/// How the ledger writes times and days: ISO-8601 to the millisecond with the local offset, and local calendar days.
/// Making a formatter costs far more than using one, and the whole file is read at launch, two times an item, so
/// formatters are made once per line for writing, and the ledger's own times are read without one.
enum AttentionTime {
    /// For example 2026-09-30T08:14:03.120-04:00.
    static func string(_ date: Date, in zone: TimeZone) -> String {
        formatter(in: zone).string(from: date)
    }

    /// Writes times in the zone; keep it for as many times as there are to write.
    static func formatter(in zone: TimeZone) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = zone
        return formatter
    }

    /// Any offset; a time without milliseconds is read too.
    static func date(_ text: String) -> Date? {
        var text = text
        if let date = text.withUTF8(fixedFormat) { return date }
        if let date = withMilliseconds.date(from: text) { return toTheMillisecond(date) }
        return wholeSeconds.date(from: text)
    }

    /// The form the ledger writes, "2026-09-30T08:14:03.120-04:00", with or without the milliseconds and with "Z" for
    /// UTC, read by hand: a formatter takes about 20 µs a time, which was most of reading the file at launch. Anything
    /// else, or a year outside 1900-9999, is nil, for the formatters to read.
    private static func fixedFormat(_ text: UnsafeBufferPointer<UInt8>) -> Date? {
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= text.count else { return nil }
            var value = 0
            for index in start..<start + count {
                guard (48...57).contains(text[index]) else { return nil }
                value = value * 10 + Int(text[index] - 48)
            }
            return value
        }
        func byte(_ index: Int, is character: Unicode.Scalar) -> Bool { index < text.count && text[index] == UInt8(ascii: character) }
        guard byte(4, is: "-"), byte(7, is: "-"), byte(10, is: "T"), byte(13, is: ":"), byte(16, is: ":"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1900...9999).contains(year), (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        guard day >= 1, day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] else { return nil }
        var next = 19, milliseconds = 0
        if byte(next, is: ".") {
            guard let fraction = number(20, 3) else { return nil }
            milliseconds = fraction
            next = 23
        }
        var offset = 0
        if byte(next, is: "Z") {
            next += 1
        } else if byte(next, is: "+") || byte(next, is: "-") {
            guard let hours = number(next + 1, 2), byte(next + 3, is: ":"), let minutes = number(next + 4, 2), hours <= 18, minutes < 60 else {
                return nil
            }
            offset = (hours * 3_600 + minutes * 60) * (byte(next, is: "-") ? -1 : 1)
            next += 6
        } else {
            return nil
        }
        guard next == text.count else { return nil }
        // Days since 1970-01-01 in the proleptic Gregorian calendar, counting years from March so a leap day ends one.
        let shifted = month <= 2 ? year - 1 : year
        let era = shifted / 400, yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return toTheMillisecond(Date(timeIntervalSince1970: Double(seconds) + Double(milliseconds) / 1_000))
    }

    // ISO8601DateFormatter is thread-safe, and reading never changes these.
    private static let withMilliseconds = formatter(in: TimeZone(secondsFromGMT: 0)!)
    private static let wholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// "yyyy-MM-dd" in the zone.
    static func day(of date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The same instant the file will read back.
    static func toTheMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
