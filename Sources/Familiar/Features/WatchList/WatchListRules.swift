import Foundation

/// How a watch decides whether an item is as it should be right now, and what to tell the person. Only the latest check
/// counts: an earlier one is never evidence of anything, and what the person was last told is kept only so the same
/// news isn't repeated every time the watch checks.
enum WatchListRules {
    /// Numbers count as the same within half a cent; the rest of the margin absorbs floating-point noise.
    static let tolerance = 0.005 + 1e-9

    /// What counts as right for an item, from its first check that works: every field it reported, or only the fields
    /// the person named, then whatever they said explicitly (which also adds fields).
    static func expectations(from state: [String: WatchListValue], fields: [String]?,
                             expect: [String: WatchListValue]) -> [String: WatchListValue] {
        var expected = fields.map { names in state.filter { names.contains($0.key) } } ?? state
        for (field, value) in expect { expected[field] = value }
        return expected
    }

    /// Compares what a check shows now with what counts as right. A field the check didn't report is not a difference:
    /// the row says it wasn't reported, and nothing is alerted.
    static func compare(_ state: [String: WatchListValue], with expected: [String: WatchListValue]) -> WatchListStatus {
        let differences = expected.keys.sorted().compactMap { field -> WatchListDifference? in
            guard let now = state[field], let wanted = expected[field], !same(now, wanted) else { return nil }
            return WatchListDifference(field: field, now: now.normalized, expected: wanted.normalized)
        }
        return differences.isEmpty ? .asExpected : .notAsExpected(differences)
    }

    /// Whether what a check shows now counts as what was expected: numbers within half a cent, text exactly once
    /// trimmed, lists as sets (order doesn't matter), yes or no, and none only as none (an empty list is none). A number
    /// or a yes or no written as text, the way a person or the model may give it ("12.33", "$12.33", "yes"), counts as
    /// that number or answer, and a single text as a list of one.
    static func same(_ a: WatchListValue, _ b: WatchListValue) -> Bool {
        switch (a.normalized, b.normalized) {
        case let (.number(x), .number(y)): return abs(x - y) <= tolerance
        case let (.text(x), .text(y)): return x == y
        case let (.flag(x), .flag(y)): return x == y
        case let (.list(x), .list(y)): return x == y
        case (.none, .none): return true
        case let (.number(x), .text(text)), let (.text(text), .number(x)):
            return number(in: text).map { abs($0 - x) <= tolerance } ?? false
        case let (.flag(x), .text(text)), let (.text(text), .flag(x)):
            return flag(in: text) == x
        case let (.list(list), .text(text)), let (.text(text), .list(list)):
            return list == [text]
        default: return false
        }
    }

    /// A number written as text: "12.33", "$12.33", "1,299.00".
    static func number(in text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "$€£¥₹ "))
        t = t.replacingOccurrences(of: #",(?=\d{3}(\D|$))"#, with: "", options: .regularExpression)
        guard !t.isEmpty, let value = Double(t), value.isFinite else { return nil }
        return value
    }

    /// A yes or no written as text.
    static func flag(in text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "y": return true
        case "false", "no", "n": return false
        default: return nil
        }
    }

    /// Records one check of an item and says what to tell the person, if anything:
    /// - as expected → not as expected, or not as expected in another way than they were last told: the differences;
    /// - not as expected → as expected: back to what they expected;
    /// - couldn't check twice in a row: why, once, until a check works again. Working again is news only when the
    ///   item is not how they were last told it was;
    /// - never on the item's first check, and never when `quiet` (the person sees the result where they asked, in the
    ///   chat): the result only becomes what they were told.
    /// Expectations come from the first check that works, so an item whose first check failed gets them later.
    static func apply(_ outcome: WatchListOutcome, to item: inout WatchListItem, fields: [String]?,
                      expect: [String: WatchListValue], at time: Date, quiet: Bool = false) -> WatchListAlert.Kind? {
        let silent = quiet || item.checkedAt == nil
        item.checkedAt = time
        switch outcome {
        case .failed(let reason):
            item.failures += 1
            item.status = .couldNotCheck(reason)
            guard item.failures >= 2, !item.notifiedCouldNotCheck else { return nil }
            item.notifiedCouldNotCheck = true
            return silent ? nil : .couldNotCheck(reason)
        case .checked(let reading):
            item.failures = 0
            item.notifiedCouldNotCheck = false
            if let title = reading.title { item.title = title }
            if let url = reading.url { item.url = url }
            item.state = reading.state
            item.facts = reading.facts
            let expected = item.expected ?? expectations(from: reading.state, fields: fields, expect: expect)
            item.expected = expected
            let verdict = compare(reading.state, with: expected)
            item.status = verdict
            let told = item.notified
            item.notified = verdict
            if silent { return nil }
            switch verdict {
            case .notAsExpected(let differences):
                if case .notAsExpected(let earlier)? = told, earlier == differences { return nil }
                return .notAsExpected(differences)
            default:
                if case .notAsExpected? = told { return .backToExpected }
                return nil
            }
        }
    }

    /// One run's couldn't-check alerts, so a site that is down or a sign-in that ran out is one notification for the
    /// watch rather than one per item: three or more items that failed for the same reason become one alert.
    static func grouped(_ alerts: [WatchListAlert]) -> [WatchListAlert] {
        var reasons: [String] = []
        var byReason: [String: [WatchListAlert]] = [:]
        for alert in alerts {
            guard case .couldNotCheck(let reason) = alert.kind else { continue }
            if byReason[reason] == nil { reasons.append(reason) }
            byReason[reason, default: []].append(alert)
        }
        return reasons.flatMap { reason -> [WatchListAlert] in
            let same = byReason[reason] ?? []
            guard same.count >= 3, let first = same.first else { return same }
            return [WatchListAlert(watchID: first.watchID, watchName: first.watchName, itemKey: "", title: first.watchName,
                                   kind: .couldNotCheckItems(same.count, reason))]
        } + alerts.filter { if case .couldNotCheck = $0.kind { return false } else { return true } }
    }

    /// The person changed what counts as right (in the chat, which shows the result): the item is compared again with
    /// what its last check showed, and that is what they were told. An item that couldn't be checked keeps its status,
    /// and one that never worked gets the new values with the rest of its expectations at its first check that works.
    static func reexpect(_ item: inout WatchListItem, with expect: [String: WatchListValue]) {
        guard var expected = item.expected else { return }
        for (field, value) in expect { expected[field] = value }
        item.expected = expected
        guard let state = item.state, item.status?.isVerdict == true else { return }
        let verdict = compare(state, with: expected)
        item.status = verdict
        item.notified = verdict
    }

    /// "in_stock" → "In stock", "strikeThrough" → "Strike through", "SKU" → "SKU".
    static func label(_ field: String) -> String {
        var words = ""
        let characters = Array(field.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "))
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : " "
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if character.isUppercase, previous.isLowercase || previous.isNumber, next.isLowercase {
                words += " " + character.lowercased()
            } else {
                words.append(character)
            }
        }
        let tidy = words.split(separator: " ").joined(separator: " ")
        return tidy.prefix(1).uppercased() + tidy.dropFirst()
    }

    /// Plain words from a script's error: its first line, without the script's file name or the Python error type.
    static func reason(_ error: String) -> String {
        var line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.replacingOccurrences(of: #"^[\w.-]+\.py failed: "#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^[A-Za-z_][\w.]*(Error|Exception): "#, with: "", options: .regularExpression)
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return "The check failed without saying why." }
        return WatchListValue.clip(line, 200)
    }
}

/// When a watch checks next.
enum WatchListSchedule {
    /// A tick that lands a moment early still counts, so a watch never slips a whole tick each round.
    static let slack: TimeInterval = 5

    static func isDue(_ watch: WatchListWatch, at now: Date) -> Bool {
        guard !watch.paused, !watch.items.isEmpty else { return false }
        guard let last = watch.lastRunAt else { return true }
        if last > now.addingTimeInterval(60) { return true }   // the clock went back: don't wait out the difference
        return now.timeIntervalSince(last) >= TimeInterval(watch.everyMinutes * 60) - slack
    }

    static func next(_ watch: WatchListWatch, after now: Date) -> Date? {
        guard !watch.paused, !watch.items.isEmpty else { return nil }
        guard let last = watch.lastRunAt else { return now }
        return max(now, last.addingTimeInterval(TimeInterval(watch.everyMinutes * 60)))
    }
}
