import Foundation

/// The attention test's numbers, worked out from the ledger alone, so deleting runs or cards never changes them: what
/// each day read, showed and left in the rest, what the person said about it, the daily line, a day's rest in the
/// order a miss is likeliest, and the week measured against the pass bar set before the test began. A message counts
/// once, on the local day a card step first read it. Pure, so every number can be tested without a file.
struct AttentionNumbers {
    /// The pass bar: show at most 20% of what was read, and open on 5 of 7 days. Misses are counted but are not part of
    /// it: a week holds too few worth-it messages to measure a miss rate, and what is worth it differs from person to
    /// person, so they are a long-term measure of how well Noteling learns what matters to you.
    static let shownBar = 20, openedBar = 5, weekDays = 7
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
        /// Messages past the script's limit that no read returned, which are not counted as read: what the day's reads
        /// left out where no earlier read had looked.
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
        /// "Missed 1 of 26 worth-it": counted, not part of the pass bar.
        var missed: String
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
    /// Only a copy for a later time the same day changes it; see `at(_:)`.
    private(set) var now: Date
    let timeZone: TimeZone
    /// "yyyy-MM-dd" in `timeZone`.
    let today: String
    private let calendar: Calendar
    /// For each day a script source was read, how many of its messages were past the script's limit.
    private let cutOff: [String: Int]
    /// The first open that counts, or the first thing done in the pack, on each day.
    private let firstOpen: [String: Date]
    /// The messages of the days a screen can show, sorted: the daily line looks back six days, and a week never
    /// reaches further than six days either side of today. Any other day's are sorted when it is asked for.
    private(set) var shownDays: [String: Day] = [:]

    init(index: AttentionIndex, now: Date, timeZone: TimeZone) {
        self.index = index
        self.now = now
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        today = AttentionTime.day(of: now, in: timeZone)

        var cutOff: [String: Int] = [:]
        for reads in index.sortedReads.values {
            // Each read counts only what it left out where no earlier read looked, so a day's add up. A read that
            // doesn't say where its window starts may cut off what another that day did, so of those only the most counts.
            var most: [String: Int] = [:]
            for read in reads {
                if read.since == nil {
                    most[read.day] = max(most[read.day] ?? 0, read.cutOff)
                } else {
                    cutOff[read.day, default: 0] += read.cutOff
                }
            }
            cutOff.merge(most, uniquingKeysWith: +)
        }
        self.cutOff = cutOff
        firstOpen = index.firstOpened.merging(index.firstActive, uniquingKeysWith: min)
        let reach = Self.weekDays - 1
        for day in (-reach...reach).map({ self.day(today, plus: $0) }) {
            if let keys = index.keysByDay[day], !keys.isEmpty { shownDays[day] = Day(day, keys: keys, index: index) }
        }
    }

    /// The same numbers at a later time on the same day: what the clock says moves on, and the days are not worked
    /// out again.
    func at(_ now: Date) -> AttentionNumbers {
        var numbers = self
        numbers.now = now
        return numbers
    }

    func day(_ day: String) -> Day {
        var counts = shownDays[day] ?? index.keysByDay[day].flatMap { $0.isEmpty ? nil : Day(day, keys: $0, index: index) } ?? Day(day: day)
        if let cutOff = cutOff[day] {
            counts.wasRead = true
            counts.cutOff = cutOff
        }
        counts.firstOpen = firstOpen[day]
        return counts
    }

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

        // Today still counts until it is opened; days to come can all be.
        let stillOpen = days.filter { $0.day >= today && $0.firstOpen == nil }.count
        let opened: Verdict = total.daysOpened >= Self.openedBar ? .pass : total.daysOpened + stillOpen < Self.openedBar ? .fail : .onTrack

        let verdicts = [showed, opened]
        let overall = verdicts.allSatisfy { $0 == .pass } ? "PASS" : verdicts.contains(.fail) ? "FAIL"
            : rolling ? "Last 7 days" : "Day \(number) of \(Self.weekDays)"
        return Week(days: days, dayNumber: number, startDay: start,
            title: rolling ? "Last 7 days" : "Day \(number) of \(Self.weekDays) · started \(format(start, "EEE MMM d"))",
            total: total,
            showed: Bar(verdict: showed, text: showedText, bar: "at most \(Self.shownBar)%"),
            missed: "Missed \(total.missed) of \(worthIt) worth-it",
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

    // MARK: - Mail read from the screen

    /// One quiet line saying that a mail job read from the screen ran in the same card steps as the script on `days`,
    /// such as the week's days read or the one day a rest shows. If it reads the same inbox, a message shown on its card
    /// counts as shown only when the card names the message's Message-ID, and otherwise lands in the rest. Which inbox
    /// it reads is not known here, so the line says "if". Removing the job is only suggested, and only while it is
    /// `active`, if that is known. Nil when none ran on those days.
    func screenRead(on days: [String], active: Set<UUID>? = nil) -> String? {
        let ran = days.filter { day in day <= today && index.screenReads[day]?.isEmpty == false }
        guard let last = ran.max() else { return nil }
        var names: [UUID: String] = [:]
        for day in ran.sorted() { names.merge(index.screenReads[day] ?? [:]) { _, later in later } }
        let jobs = names.sorted { ($0.value, $0.key.uuidString) < ($1.value, $1.key.uuidString) }
        let removable = jobs.filter { active?.contains($0.key) ?? true }
        let one = jobs.count == 1
        let when = ran.count == 1 ? last == today ? "today" : last == day(today, plus: -1) ? "yesterday" : "on " + weekday(last)
            : "on \(ran.count) days"
        var text = "Your screen-read mail job\(one ? "" : "s") \(Self.list(jobs.map(\.value))) also ran \(when). "
            + "If \(one ? removable.isEmpty ? "it read" : "it reads" : "they read") the same inbox, "
            + "a message shown on \(one ? "its card" : "one of their cards") can land in the rest here"
        if !removable.isEmpty {
            text += ", and removing \(removable.count == jobs.count ? one ? "it" : "them" : Self.list(removable.map(\.value)))"
                + " in Manage sources keeps the numbers clean"
        }
        return text + "."
    }

    /// “A”, “B” and “C”.
    private static func list(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        return quoted.count < 2 ? quoted.joined() : quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
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
    init(_ day: String, keys: Set<String>, index: AttentionIndex) {
        self.init(day: day, wasRead: true)
        // When each arrived, looked up once rather than at every comparison.
        let arrived = keys.map { key -> (key: String, at: Date) in
            guard let item = index.item[key] else { return (key, .distantPast) }
            return (key, item.received ?? item.readAt)
        }
        let newestFirst = arrived.sorted { $0.at != $1.at ? $0.at > $1.at : $0.key < $1.key }.map(\.key)
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
