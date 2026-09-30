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

    /// What one card step read from script sources and which of those items it showed as cards.
    struct Sorted: Codable, Equatable {
        var runIDs: [UUID]
        var backfilled: Bool
        var sources: [Source]
        var items: [AttentionItem]

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

/// One item a card step read, with the facts a later filter could learn from. Copied into every event about it,
/// so the ledger stands on its own after runs and cards are deleted. Mail fields are nil when the read had none.
/// At its longest an item is about 1.25 KB of JSON, so a 200-item `sorted` line is about 250 KB.
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
/// formatters are made once for reading and once per line for writing.
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
        if let date = withMilliseconds.date(from: text) { return toTheMillisecond(date) }
        return wholeSeconds.date(from: text)
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
