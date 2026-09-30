import Foundation

/// The attention test's numbers, worked out from the ledger alone, so deleting runs or cards never changes them: what
/// each day read, showed and left in the rest, what the person said about it, the daily line, a day's rest in the
/// order a miss is likeliest, and the week measured against the pass bar set before the test began. A message counts
/// once, on the local day a card step first read it. Pure, so every number can be tested without a file.
struct AttentionNumbers {
    /// The pass bar: show at most 20% of what was read, miss under 1% of what was worth it, open on 5 of 7 days.
    static let shownBar = 20, missBar = 1, openedBar = 5, weekDays = 7
    /// A read whose window starts more than this after the previous read ended left mail unread.
    static let gapSlack: TimeInterval = 10 * 60
    /// A source not read for longer than this says so.
    static let staleAfter: TimeInterval = 26 * 3_600

    /// One local day, holding the messages first read on it.
    struct Day: Equatable {
        /// "yyyy-MM-dd".
        let day: String
        /// A card step read a script source this day, even if the read found nothing.
        var wasRead = false
        /// The day's shown messages and the rest, newest first.
        var shownKeys: [String] = []
        var restKeys: [String] = []
        /// Shown messages the person said were worth their notice: with a thumb, or guessed from what they did.
        var yesTapped = 0, yesGuessed = 0
        /// Shown messages the person said were not, the same two ways.
        var noTapped = 0, noGuessed = 0
        /// Shown messages with a strong thumb either way.
        var strong = 0
        /// Shown messages with neither a thumb nor a guess.
        var leftAlone = 0
        /// Messages with an explanation, shown or not.
        var explained = 0
        /// Messages in the rest the person said should have been shown, whichever day they said it.
        var missed = 0
        /// The rest is empty, or it was scrolled to its end.
        var restChecked = true
        /// Messages past the script's limit, which are not counted as read: for each source, the most any of the
        /// day's reads left out.
        var cutOff = 0
        /// The day's first open that counts, or the first thing done in the pack, whichever came first.
        var firstOpen: Date?

        var read: Int { shownKeys.count + restKeys.count }
        var shown: Int { shownKeys.count }
        var restCount: Int { restKeys.count }
        var yes: Int { yesTapped + yesGuessed }
        var no: Int { noTapped + noGuessed }
    }

    /// The line on the folders screen, about `day`, with its hover text.
    struct Line: Equatable {
        var day: String
        var text: String
        var help: String
    }

    /// A day's rest, likeliest misses first; lists and promotions follow under their own divider.
    struct Rest: Equatable {
        var items: [AttentionItem]
        var lists: [AttentionItem]
    }

    /// Pass and fail are final; before day 7 a bar is on or off track. Pending says what the person still has to
    /// check, and a bar with nothing to measure yet says so.
    enum Verdict: Equatable {
        case pass, fail, onTrack, offTrack, pending(String), notMeasured
    }

    /// One bar of the pass bar: its verdict, what was measured and the bar it is measured against.
    struct Bar: Equatable {
        var verdict: Verdict
        var text: String
        var bar: String
    }

    /// The days of the week so far, added up.
    struct Total: Equatable {
        var read = 0, shown = 0, yesTapped = 0, yesGuessed = 0, no = 0, missed = 0, cutOff = 0
        var tapped = 0, guessed = 0, strong = 0, explained = 0
        var daysSoFar = 0, daysRead = 0, daysChecked = 0, daysOpened = 0
        var yes: Int { yesTapped + yesGuessed }

        fileprivate mutating func add(_ day: Day) {
            read += day.read; shown += day.shown; yesTapped += day.yesTapped; yesGuessed += day.yesGuessed
            no += day.no; missed += day.missed; cutOff += day.cutOff
            tapped += day.yesTapped + day.noTapped; guessed += day.yesGuessed + day.noGuessed
            strong += day.strong; explained += day.explained
            daysSoFar += 1
            if day.wasRead { daysRead += 1 }
            if day.wasRead && day.restChecked { daysChecked += 1 }
            if day.firstOpen != nil { daysOpened += 1 }
        }
    }

    /// Seven days from the first day read; after day 7, the last seven ending today.
    struct Week: Equatable {
        /// Oldest first; days still to come are empty.
        var days: [Day]
        /// Today's place counting the first day read as day 1.
        var dayNumber: Int
        var startDay: String
        /// "Day 6 of 7 · started Thu Sep 24", or "Last 7 days" once the window rolls.
        var title: String
        var total: Total
        var showed: Bar
        var missed: Bar
        var opened: Bar
        /// "PASS", "FAIL", or where the test stands, such as "Day 6 of 7".
        var overall: String
        /// Stretches of mail no read covered, and a source not read for over a day.
        var gaps: [String]
        /// What no misses can and cannot prove, when there were none.
        var power: String?
        var labels: String
    }

    let index: AttentionIndex
    let now: Date
    let timeZone: TimeZone
    /// "yyyy-MM-dd" in `timeZone`.
    let today: String
    private let calendar: Calendar
    private let days: [String: Day]

    init(index: AttentionIndex, now: Date, timeZone: TimeZone) {
        self.index = index
        self.now = now
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        today = AttentionTime.day(of: now, in: timeZone)

        let keys = index.firstDay.reduce(into: [String: [String]]()) { $0[$1.value, default: []].append($1.key) }
        var days = keys.reduce(into: [String: Day]()) { $0[$1.key] = Day($1.key, keys: $1.value, index: index) }
        for reads in index.sortedReads.values {
            // A 24-hour window read twice a day cuts off the same messages twice, so only the most counts.
            let cutOff = reads.reduce(into: [String: Int]()) { most, read in
                most[read.day] = max(most[read.day] ?? 0, read.truncated ? max(0, read.arrived - read.returned) : 0)
            }
            for (day, count) in cutOff {
                days[day, default: Day(day: day)].wasRead = true
                days[day]?.cutOff += count
            }
        }
        for (day, at) in index.firstOpened.merging(index.firstActive, uniquingKeysWith: min) {
            days[day, default: Day(day: day)].firstOpen = at
        }
        self.days = days
    }

    func day(_ day: String) -> Day { days[day] ?? Day(day: day) }

    /// The day `offset` days after `day`, which can be negative.
    func day(_ day: String, plus offset: Int) -> String {
        guard let noon = noon(day), let date = calendar.date(byAdding: .day, value: offset, to: noon) else { return day }
        return AttentionTime.day(of: date, in: timeZone)
    }

    // MARK: - The daily line

    /// Today's numbers, or those of the latest day read in the last seven, named. Nil when none of them was read.
    var line: Line? {
        guard let shown = (0..<Self.weekDays).map({ day(today, plus: -$0) }).first(where: { day($0).wasRead }) else { return nil }
        let counts = day(shown)
        let prefix = shown == today ? "" : shown == day(today, plus: -1) ? "Yesterday: " : weekday(shown) + ": "
        var text = prefix + "Read \(counts.read) → showed \(counts.shown) · you said yes to \(counts.yes) · "
        text += !counts.restChecked && counts.missed == 0 ? "\(counts.restCount) in the rest" : "\(counts.missed) missed"
        if counts.cutOff > 0 { text += " · \(counts.cutOff) cut off" }
        return Line(day: shown, text: text,
                    help: "\(counts.yes) yes: \(counts.yesTapped) you tapped, \(counts.yesGuessed) guessed from what you did")
    }

    // MARK: - The rest

    /// The day's messages that were not shown, likeliest misses first. A message whose copy is older than the index
    /// keeps is counted but cannot be listed.
    func restItems(on day: String) -> Rest {
        let items = self.day(day).restKeys.compactMap { index.item[$0] }.sorted(by: Self.likelierMiss)
        return Rest(items: items.filter { $0.bulk != true }, lists: items.filter { $0.bulk == true })
    }

    /// Marked important first, then the Primary tab, then newest.
    private static func likelierMiss(_ a: AttentionItem, _ b: AttentionItem) -> Bool {
        if (a.important == true) != (b.important == true) { return a.important == true }
        if (a.tab == "primary") != (b.tab == "primary") { return a.tab == "primary" }
        return newer(a, b)
    }

    /// By when it arrived, or when it was read for a message without mail facts.
    private static func newer(_ a: AttentionItem, _ b: AttentionItem) -> Bool {
        let first = a.received ?? a.readAt, second = b.received ?? b.readAt
        return first != second ? first > second : a.key < b.key
    }

    // MARK: - The week

    /// Nil until a card step has read a script source.
    var week: Week? {
        guard let start = index.sortedReads.values.flatMap({ $0.map(\.day) }).min() else { return nil }
        let number = max(1, daysBetween(start, today) + 1)
        let rolling = number > Self.weekDays
        let first = rolling ? day(today, plus: 1 - Self.weekDays) : start
        let days = (0..<Self.weekDays).map { day(day(first, plus: $0)) }
        var total = Total()
        for day in days where day.day <= today { total.add(day) }
        // Day 7 is final once its read is in, so a verdict given at midnight is not taken back when the morning's read
        // lands; a rolling window is always final.
        let final = rolling || number == Self.weekDays && day(today).wasRead

        let within = total.shown * 100 <= total.read * Self.shownBar
        let showed: Verdict = total.read == 0 ? .notMeasured : within ? (final ? .pass : .onTrack) : (final ? .fail : .offTrack)
        // Rounded to the nearest, except that a share over the bar rounds up, so 20.2% never reads as 20%.
        let percent = total.read == 0 ? 0
            : within ? (total.shown * 200 + total.read) / (total.read * 2) : (total.shown * 100 + total.read - 1) / total.read
        let showedText = total.read == 0 ? "Nothing read yet" : "Showed \(percent)% of what was read"

        let worthIt = total.yes + total.missed
        let unchecked = days.filter { $0.day <= today && $0.wasRead && !$0.restChecked }.map { weekday($0.day) }
        let missed: Verdict
        if worthIt == 0 {
            missed = .notMeasured
        } else if total.missed > 0 && total.missed * 100 >= worthIt * Self.missBar {
            missed = final ? .fail : .offTrack
        } else if !unchecked.isEmpty {
            missed = .pending("check the rest for " + unchecked.joined(separator: ", "))
        } else {
            missed = final ? .pass : .onTrack
        }
        var missedText = "Missed \(total.missed) of \(worthIt) worth-it"
        if case .pending(let reason) = missed { missedText += " · " + reason }

        // Today still counts until it is opened; days to come can all be.
        let stillOpen = days.filter { $0.day >= today && $0.firstOpen == nil }.count
        let opened: Verdict = total.daysOpened >= Self.openedBar ? .pass : total.daysOpened + stillOpen < Self.openedBar ? .fail : .onTrack

        let verdicts = [showed, missed, opened]
        let overall = verdicts.allSatisfy { $0 == .pass } ? "PASS" : verdicts.contains(.fail) ? "FAIL"
            : rolling ? "Last 7 days" : "Day \(number) of \(Self.weekDays)"
        return Week(days: days, dayNumber: number, startDay: start,
            title: rolling ? "Last 7 days" : "Day \(number) of \(Self.weekDays) · started \(format(start, "EEE MMM d"))",
            total: total,
            showed: Bar(verdict: showed, text: showedText, bar: "at most \(Self.shownBar)%"),
            missed: Bar(verdict: missed, text: missedText, bar: "under \(Self.missBar)%"),
            opened: Bar(verdict: opened, text: "Opened on \(total.daysOpened) day\(total.daysOpened == 1 ? "" : "s")",
                        bar: "\(Self.openedBar) of \(Self.weekDays)"),
            overall: overall, gaps: gaps(after: noon(first).map { calendar.startOfDay(for: $0) } ?? now),
            // The rule of three: 0 misses in N cannot rule out, at 95%, a true rate up to 3/N, which is no bound at all
            // below 3.
            power: total.missed == 0 && worthIt > 0
                ? "0 of \(worthIt) can't rule out a true miss rate up to \(min(100, (300 + worthIt - 1) / worthIt))% (95%)" : nil,
            labels: "\(total.tapped) tapped (\(total.strong) strong, \(total.explained) explained) · \(total.guessed) guessed"
                + " · \(total.cutOff) cut off")
    }

    /// For each script source read since `start`, the stretches between reads that no read covered, ending after
    /// `start`, and how long it has gone unread when that is over a day. A source last read before `start`, such as a
    /// mail job removed and set up again, is left out, unless no source was read since. Sources are named as last
    /// read, and only when there is more than one.
    private func gaps(after start: Date) -> [String] {
        let all = index.sortedReads.values.compactMap { reads in reads.last.map { (reads: reads, last: $0) } }
        let recent = all.filter { $0.last.collectedAt >= start }
        let sources = (recent.isEmpty ? all.max { $0.last.collectedAt < $1.last.collectedAt }.map { [$0] } ?? [] : recent)
            .sorted { ($0.last.sourceName, $0.last.collectedAt) < ($1.last.sourceName, $1.last.collectedAt) }
        var lines: [String] = []
        for (reads, last) in sources {
            let from = sources.count > 1 ? " from \(last.sourceName)" : ""
            for (previous, read) in zip(reads, reads.dropFirst()) {
                guard let since = read.since, since > previous.collectedAt + Self.gapSlack, since > start else { continue }
                lines.append("Not read\(from): \(stamp(previous.collectedAt)) → \(stamp(since))")
            }
            if now.timeIntervalSince(last.collectedAt) > Self.staleAfter {
                lines.append("No read\(from) since \(stamp(last.collectedAt))")
            }
        }
        return lines
    }

    // MARK: - Days and dates

    /// Noon on the day, which steps across days without tripping on a clock change.
    private func noon(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private func daysBetween(_ first: String, _ second: String) -> Int {
        guard let from = noon(first), let to = noon(second) else { return 0 }
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// "Mon".
    private func weekday(_ day: String) -> String { format(day, "EEE") }

    /// "Sat 26 08:10".
    private func stamp(_ date: Date) -> String { format(date, "EEE d HH:mm") }

    /// A day, "yyyy-MM-dd", or a time as the screens name it, in the numbers' zone: "Tue 29" is `format(day, "EEE d")`.
    func format(_ day: String, _ pattern: String) -> String { noon(day).map { format($0, pattern) } ?? day }

    func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private extension AttentionNumbers.Day {
    /// The day's messages, split into shown and the rest, each counted by its label as it stands now.
    init(_ day: String, keys: [String], index: AttentionIndex) {
        self.init(day: day, wasRead: true)
        func arrived(_ key: String) -> Date {
            guard let item = index.item[key] else { return .distantPast }
            return item.received ?? item.readAt
        }
        let newestFirst = keys.sorted { arrived($0) != arrived($1) ? arrived($0) > arrived($1) : $0 < $1 }
        for key in newestFirst {
            let label = index.labels[key] ?? .init()
            if label.explanation != nil { explained += 1 }
            guard index.shownKeys.contains(key) else {
                restKeys.append(key)
                if index.missedKeys.contains(key) { missed += 1 }
                continue
            }
            shownKeys.append(key)
            switch label.state {
            case .yes: yesTapped += 1
            case .strongYes: yesTapped += 1; strong += 1
            case .guessYes: yesGuessed += 1
            case .no: noTapped += 1
            case .strongNo: noTapped += 1; strong += 1
            case .guessNo: noGuessed += 1
            case .notSet: leftAlone += 1
            }
        }
        restChecked = restKeys.isEmpty || index.restCheckedDays.contains(day)
    }
}

extension AttentionLedger {
    /// The numbers as the ledger stands now, in its zone.
    var numbers: AttentionNumbers { AttentionNumbers(index: index, now: clock(), timeZone: timeZone) }
}
