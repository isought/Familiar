import Foundation

/// One thing a watch's check reported about an item: text, a number, yes or no, a list of texts, or none (JSON null).
/// What counts as right is kept the same way, and both are what an alert shows.
enum WatchListValue: Equatable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case list([String])
    case none

    static let textLimit = 500
    static let listLimit = 50

    /// From what a script returned or the model sent (JSONSerialization types). A list holds texts: numbers and yes or
    /// no in it become text, and a null in it is dropped. An object, or a list holding objects, is kept as its JSON
    /// text, so it is still compared.
    init(json value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .none
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .flag(number.boolValue) }
            else if number.doubleValue.isFinite { self = .number(number.doubleValue) }
            else { self = .text(number.stringValue) }
        case let text as String:
            self = .text(WatchListValue.clip(text, WatchListValue.textLimit))
        case let array as [Any]:
            var texts: [String] = []
            for element in array {
                switch element {
                case is NSNull: continue
                case let text as String: texts.append(WatchListValue.clip(text, 200))
                case let number as NSNumber: texts.append(CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "yes" : "no") : number.stringValue)
                default: self = .text(WatchListValue.jsonText(array, limit: WatchListValue.textLimit)); return
                }
            }
            self = .list(Array(texts.prefix(WatchListValue.listLimit)))
        case let other?:
            self = .text(WatchListValue.jsonText(other, limit: WatchListValue.textLimit))
        }
    }

    /// Back to JSON, for a script's arguments and the chat's summaries: whole numbers as integers.
    var json: Any {
        switch self {
        case .text(let text): return text
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? Int(number) as Any : number
        case .flag(let flag): return flag
        case .list(let list): return list
        case .none: return NSNull()
        }
    }

    /// In plain words, as a row or an alert shows it: 12.33, yes, Deal, Overall pick, none.
    var words: String {
        switch self {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "empty" : trimmed
        case .number(let number): return Self.format(number)
        case .flag(let flag): return flag ? "yes" : "no"
        case .list(let list): return list.isEmpty ? "none" : list.joined(separator: ", ")
        case .none: return "none"
        }
    }

    /// The form two values are compared and remembered in: text trimmed; a list trimmed, without repeats and in order;
    /// an empty list as none.
    var normalized: WatchListValue {
        switch self {
        case .text(let text): return .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .list(let list):
            let texts = Set(list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            return texts.isEmpty ? .none : .list(texts.sorted())
        default: return self
        }
    }

    /// Whole numbers without decimals; anything else with at least two, the way prices are written.
    static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func jsonText(_ value: Any, limit: Int) -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return clip("\(value)", limit) }
        return clip(String(decoding: data, as: UTF8.self), limit)
    }
}

extension WatchListValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .none }
        else if let flag = try? container.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let text = try? container.decode(String.self) { self = .text(text) }
        else { self = .list(try container.decode([String].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        case .list(let list): try container.encode(list)
        case .none: try container.encodeNil()
        }
    }
}

/// One field that isn't what counts as right: what the check shows now, and what was expected.
struct WatchListDifference: Codable, Equatable {
    var field: String
    var now: WatchListValue
    var expected: WatchListValue

    /// "Price: 13.95 — expected 12.33"
    var words: String { "\(WatchListRules.label(field)): \(now.words) — expected \(expected.words)" }
}

/// What an item's last check said: as expected, not as expected (and how), or that it couldn't check (and why).
enum WatchListStatus: Equatable {
    case asExpected
    case notAsExpected([WatchListDifference])
    case couldNotCheck(String)

    /// Whether this says how the item is, rather than that it couldn't be checked.
    var isVerdict: Bool {
        if case .couldNotCheck = self { return false }
        return true
    }
}

extension WatchListStatus: Codable {
    private enum CodingKeys: String, CodingKey { case kind, differences, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "asExpected": self = .asExpected
        case "notAsExpected": self = .notAsExpected(try container.decodeIfPresent([WatchListDifference].self, forKey: .differences) ?? [])
        default: self = .couldNotCheck(try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .asExpected:
            try container.encode("asExpected", forKey: .kind)
        case .notAsExpected(let differences):
            try container.encode("notAsExpected", forKey: .kind)
            try container.encode(differences, forKey: .differences)
        case .couldNotCheck(let reason):
            try container.encode("couldNotCheck", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// One watched item: the key exactly as the person gave it (an id or a page address), what its last check found, what
/// counts as right for it, and what the person was last told about it.
struct WatchListItem: Equatable, Identifiable {
    var key: String
    var title: String?
    var url: String?
    /// What counts as right: set by its first check that works, then by what the person says. Nil until then.
    var expected: [String: WatchListValue]?
    /// What its last check that worked reported.
    var state: [String: WatchListValue]?
    /// The rest of what that check returned, as JSON text, for an explanation. Never shown as a cause by itself.
    var facts: String?
    var checkedAt: Date?
    var status: WatchListStatus?
    /// Checks in a row that couldn't check.
    var failures = 0
    /// What the person was last told about it, by a notification or by the chat: as expected, or not and how. Only so
    /// the same news isn't repeated; never evidence of a cause.
    var notified: WatchListStatus?
    /// They were told it couldn't be checked; cleared when a check works again.
    var notifiedCouldNotCheck = false

    init(key: String) { self.key = key }

    var id: String { key }

    /// Its title from the check, or the key as given.
    var label: String {
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? key : title
    }

    /// The page to open: the check's address for it, or the key when the person gave a page address.
    var pageURL: String? {
        if let url, !url.isEmpty { return url }
        return key.lowercased().hasPrefix("http://") || key.lowercased().hasPrefix("https://") ? key : nil
    }

    /// Fields that count but that the last check didn't report: shown, never alerted on.
    var unreported: [String] {
        guard let expected, let state else { return [] }
        return expected.keys.filter { state[$0] == nil }.sorted()
    }

    /// Red and grey rows have something to explain.
    var needsExplaining: Bool {
        switch status {
        case .notAsExpected?, .couldNotCheck?: return true
        default: return false
        }
    }
}

extension WatchListItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, title, url, expected, state, facts, checkedAt, status, failures, notified, notifiedCouldNotCheck
    }

    /// Fields a later version adds are optional here, so an older file always opens.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        expected = try container.decodeIfPresent([String: WatchListValue].self, forKey: .expected)
        state = try container.decodeIfPresent([String: WatchListValue].self, forKey: .state)
        facts = try container.decodeIfPresent(String.self, forKey: .facts)
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
        status = try container.decodeIfPresent(WatchListStatus.self, forKey: .status)
        failures = try container.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        notified = try container.decodeIfPresent(WatchListStatus.self, forKey: .notified)
        notifiedCouldNotCheck = try container.decodeIfPresent(Bool.self, forKey: .notifiedCouldNotCheck) ?? false
    }
}

/// A list of items checked together on a schedule by one pack's `watch:` script.
struct WatchListWatch: Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// The check: a pack script's tool name, e.g. shop__watch_item.
    var check: String
    var items: [WatchListItem]
    /// Extra arguments the person gave for the check, e.g. a zip code. Passed only if the script declares them.
    var args: [String: WatchListValue] = [:]
    /// Only these state fields count; nil counts every field the check reports.
    var fields: [String]?
    /// What counts as right for every item, as the person said it. Overrides what a first check finds.
    var expect: [String: WatchListValue] = [:]
    var everyMinutes = WatchListWatch.defaultMinutes
    var paused = false
    var createdAt = Date()
    var lastRunAt: Date?

    static let defaultMinutes = 15
    static let minimumMinutes = 5
    static let maximumMinutes = 240

    init(id: UUID = UUID(), name: String, check: String, items: [WatchListItem], args: [String: WatchListValue] = [:],
         fields: [String]? = nil, expect: [String: WatchListValue] = [:], everyMinutes: Int = WatchListWatch.defaultMinutes,
         paused: Bool = false, createdAt: Date = Date(), lastRunAt: Date? = nil) {
        self.id = id
        self.name = name
        self.check = check
        self.items = items
        self.args = args
        self.fields = fields
        self.expect = expect
        self.everyMinutes = WatchListWatch.clamp(everyMinutes)
        self.paused = paused
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }

    static func clamp(_ minutes: Int) -> Int { min(maximumMinutes, max(minimumMinutes, minutes)) }

    /// "every 15 minutes", "every hour", "every 2 hours"
    var everyWords: String {
        if everyMinutes % 60 == 0 { return everyMinutes == 60 ? "every hour" : "every \(everyMinutes / 60) hours" }
        return "every \(everyMinutes) minutes"
    }

    func item(_ key: String) -> WatchListItem? { items.first { $0.key == key } }
}

extension WatchListWatch: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, check, items, args, fields, expect, everyMinutes, paused, createdAt, lastRunAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        check = try container.decode(String.self, forKey: .check)
        items = try container.decodeIfPresent([WatchListItem].self, forKey: .items) ?? []
        args = try container.decodeIfPresent([String: WatchListValue].self, forKey: .args) ?? [:]
        fields = try container.decodeIfPresent([String].self, forKey: .fields)
        expect = try container.decodeIfPresent([String: WatchListValue].self, forKey: .expect) ?? [:]
        everyMinutes = WatchListWatch.clamp(try container.decodeIfPresent(Int.self, forKey: .everyMinutes) ?? WatchListWatch.defaultMinutes)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }
}

/// What one check of one item found, or why it couldn't check.
enum WatchListOutcome: Equatable {
    case checked(WatchListReading)
    case failed(String)
}

/// What a check script returned for one item.
struct WatchListReading: Equatable {
    var title: String?
    var url: String?
    var state: [String: WatchListValue]
    var facts: String?

    static let fieldLimit = 40
    static let factsLimit = 8_000

    /// A check's return value: `title`, optional `url`, `state` (an object of flat fields) and optional `facts`. An
    /// `error`, or no `state` object, means it couldn't check.
    static func parse(_ value: Any?) -> WatchListOutcome {
        guard let object = value as? [String: Any] else { return .failed("The check didn't return what it found.") }
        if let error = object["error"], !(error is NSNull), !"\(error)".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failed(WatchListRules.reason(error as? String ?? WatchListValue.jsonText(error, limit: 300)))
        }
        guard let raw = object["state"] as? [String: Any] else { return .failed("The check didn't say what it found (no state).") }
        var state: [String: WatchListValue] = [:]
        for key in raw.keys.sorted() {
            let field = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !field.isEmpty, state.count < fieldLimit else { continue }
            state[field] = WatchListValue(json: raw[key])
        }
        func text(_ key: String, _ limit: Int) -> String? {
            let value: String?
            if let string = object[key] as? String { value = string }
            else if let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.stringValue }
            else { value = nil }
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : WatchListValue.clip(trimmed, limit)
        }
        let facts = object["facts"].flatMap { $0 is NSNull ? nil : WatchListValue.jsonText($0, limit: factsLimit) }
        return .checked(WatchListReading(title: text("title", 300), url: text("url", 2_000), state: state, facts: facts))
    }
}

/// What to tell the person about one item, or about several items of a watch that couldn't be checked for one reason.
struct WatchListAlert: Equatable {
    enum Kind: Equatable {
        case notAsExpected([WatchListDifference])
        case backToExpected
        case couldNotCheck(String)
        /// How many items, and why.
        case couldNotCheckItems(Int, String)
    }

    var watchID: UUID
    var watchName: String
    /// The item, or empty when the alert is about several items.
    var itemKey: String
    /// The item's title (or its key), or the watch's name when the alert is about several items.
    var title: String
    var kind: Kind

    /// In plain words: one line per difference, "Back to what you expected", or why it couldn't check.
    var body: String {
        switch kind {
        case .notAsExpected(let differences): return differences.map(\.words).joined(separator: "\n")
        case .backToExpected: return "Back to what you expected"
        case .couldNotCheck(let reason): return "Couldn't check: \(reason)"
        case .couldNotCheckItems(let count, let reason): return "Couldn't check \(count) items: \(reason)"
        }
    }
}

struct WatchListError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
