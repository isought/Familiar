import Foundation

/// What the attention ledger holds, folded from its events: when the test started, which runs a card step has
/// sorted, the day each item was first read, whether it was ever shown, each script read's own counts, the mail jobs
/// read from the screen beside them, each item's label, the items marked missed, the days whose rest was looked through,
/// and when the pack was first opened and first used each day. Pure, so the numbers can be worked out and tested
/// without a file.
struct AttentionIndex {
    /// Items first read within this many days keep their full copy for the rest screen; older ones keep only their day.
    static let itemDays = 14

    /// One script read in a `sorted` event: what arrived and came back, for what was cut off and gaps between reads.
    struct Read: Equatable {
        /// The local day of the `sorted` event it was in.
        var day: String
        var sourceName: String
        var collectedAt: Date
        var since: Date?
        var arrived: Int
        var returned: Int
        var truncated: Bool
        /// Messages past the script's limit that no earlier read looked at: see `cutOff(_:in:zone:)`.
        var cutOff = 0
    }

    private(set) var startedAt: Date?
    private(set) var sortedRunIDs: Set<UUID> = []
    /// The local day of the first card step that sorted each key (its `sorted` event's day, as for `Read.day`), so a
    /// message read again later that day or the next counts once.
    private(set) var firstDay: [String: String] = [:]
    /// `firstDay` the other way round: the keys first read on each local day, so a day's numbers never look through
    /// every day ever read.
    private(set) var keysByDay: [String: Set<String>] = [:]
    /// Keys a card step showed in any `sorted` event.
    private(set) var shownKeys: Set<String> = []
    /// Each shown key by its Message-ID, so a card from another job that names it, such as one read from the screen,
    /// is found as that message's card.
    private(set) var shownByMessageID: [String: String] = [:]
    /// The copy of each recently read key from the `sorted` event that first held it.
    private(set) var item: [String: AttentionItem] = [:]
    /// Each script source's reads, oldest first.
    private(set) var sortedReads: [UUID: [Read]] = [:]
    /// The mail jobs a card step read from the screen beside a script read, by the local day of its `sorted` event,
    /// each with its name as last written that day.
    private(set) var screenReads: [String: [UUID: String]] = [:]
    /// Each key's thumbs, explanation and what the person did, in the order they were written.
    private(set) var labels: [String: AttentionLabels.Effective] = [:]
    /// Items the person said should have been shown, and has not taken back.
    private(set) var missedKeys: Set<String> = []
    /// The earliest open that counts on each local day: by the launcher, the menu or the task panel.
    private(set) var firstOpened: [String: Date] = [:]
    /// The earliest thing the person did in the pack each local day: opened a card, gave a label, marked a miss or
    /// looked at the rest. Kept apart from `firstOpened`, which decides whether an open is recorded.
    private(set) var firstActive: [String: Date] = [:]
    /// Days read whose rest was scrolled to its end, and has had no message join it since.
    private(set) var restCheckedDays: Set<String> = []
    /// Keys first read before this day keep only their `firstDay`.
    private(set) var keepsItemsFrom: String
    /// Every event folded so far, so one in the file twice, such as one written again after a write that failed
    /// partway, counts once.
    private var folded: Set<UUID> = []

    init(_ events: [AttentionEvent] = [], now: Date, timeZone: TimeZone) {
        self.init(events, keepsItemsFrom: Self.keepsItems(at: now, in: timeZone))
    }

    init(_ events: [AttentionEvent] = [], keepsItemsFrom day: String) {
        keepsItemsFrom = day
        for event in events { add(event) }
    }

    /// The first day whose items keep their full copy at `now`: `itemDays` days before today.
    static func keepsItems(at now: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return AttentionTime.day(of: calendar.date(byAdding: .day, value: -itemDays, to: now) ?? now, in: timeZone)
    }

    /// Moves the day items are kept from, and lets go of the copies of those first read before it, as the days roll
    /// on while Noteling keeps running. A copy already let go of is not brought back when the day moves back.
    mutating func keepItems(from day: String) {
        guard day != keepsItemsFrom else { return }
        if day > keepsItemsFrom { item = item.filter { firstDay[$0.key].map { $0 >= day } ?? false } }
        keepsItemsFrom = day
    }

    mutating func add(_ event: AttentionEvent) {
        guard folded.insert(event.id).inserted else { return }
        switch event.payload {
        case .started:
            if startedAt == nil { startedAt = event.at }
        case .sorted(let sorted):
            sortedRunIDs.formUnion(sorted.runIDs)
            for source in sorted.sources {
                let cutOff = cutOff(source, in: sorted, zone: event.timeZone)
                sortedReads[source.sourceID, default: []].append(Read(day: event.day, sourceName: source.sourceName,
                    collectedAt: source.collectedAt, since: source.since, arrived: source.arrived, returned: source.returned,
                    truncated: source.truncated, cutOff: cutOff))
                sortedReads[source.sourceID]?.sort { $0.collectedAt < $1.collectedAt }
            }
            for item in sorted.items { read(item.key, shown: item.shown, copy: item, on: event.day, backfilled: sorted.backfilled) }
            for again in sorted.seen ?? [] { read(again.key, shown: again.shown, copy: nil, on: event.day, backfilled: sorted.backfilled) }
            for screen in sorted.screenRead ?? [] { screenReads[event.day, default: [:]][screen.sourceID] = screen.sourceName }
        case .label(let label):
            labels[label.key, default: .init()].add(label.value, text: label.text)
        case .implicit(let implicit):
            labels[implicit.key, default: .init()].add(implicit.signal, retracts: implicit.retracts)
        case .miss(let miss):
            if miss.retract { missedKeys.remove(miss.key) } else { missedKeys.insert(miss.key) }
        case .opened(let opened):
            if opened.trigger.counts, firstOpened[event.day].map({ event.at < $0 }) ?? true { firstOpened[event.day] = event.at }
        case .restViewed(let viewed):
            if viewed.reachedEnd { restCheckedDays.insert(viewed.restDay) }
        case .engaged:
            break
        }
        if [.label, .miss, .restViewed, .engaged].contains(event.type), firstActive[event.day].map({ event.at < $0 }) ?? true {
            firstActive[event.day] = event.at
        }
    }

    /// How many messages a read left out past the script's limit that no earlier read of its source looked at. A script
    /// told when the last sorted read was counts those that arrived after it itself, which is exact. Otherwise it is
    /// worked out here. The script leaves out the oldest in its window, and a window can reach back over an earlier
    /// read's: when the oldest message it returned arrived before an earlier read ended, all it left out is where that
    /// read looked, returned then or cut off and counted then. Otherwise it counts what it left out less what earlier
    /// reads returned from its window; a message read then and archived or deleted since is no longer in the mailbox,
    /// so this can count too few. A read that doesn't say where its window starts counts all it left out. Worked out
    /// before the line's messages are folded in, from the copies the index keeps: a read older than those, which no
    /// screen shows, may count all it left out.
    private func cutOff(_ source: AttentionEvent.Sorted.Source, in sorted: AttentionEvent.Sorted, zone: TimeZone) -> Int {
        let left = source.truncated ? max(0, source.arrived - source.returned) : 0
        if let counted = source.cutOffSinceLastRead { return min(left, max(0, counted)) }
        guard left > 0, let since = source.since,
              let ended = sortedReads[source.sourceID]?.last(where: { $0.collectedAt < source.collectedAt })?.collectedAt,
              ended > since else { return left }
        // What this read returned: new messages in full, and those read before by the copy the index keeps.
        let copies = sorted.items.filter { $0.sourceID == source.sourceID }
            + (sorted.seen ?? []).compactMap { item[$0.key] }.filter { $0.sourceID == source.sourceID }
        if let oldest = copies.compactMap(\.received).min(), oldest <= ended { return 0 }
        let returned = Set(copies.map(\.key))
        // A message is first read after it arrives; two days' slack covers any change of zone in between.
        let from = AttentionTime.day(of: since.addingTimeInterval(-2 * 86_400), in: zone)
        var readBefore = 0
        for (day, keys) in keysByDay where day >= from {
            for key in keys where !returned.contains(key) {
                guard let copy = item[key], copy.sourceID == source.sourceID, let received = copy.received,
                      received >= since, received <= source.collectedAt else { continue }
                readBefore += 1
            }
        }
        return max(0, left - readBefore)
    }

    /// A card step read `key` on `day`, with its full copy unless an earlier line holds it. The first read dates it; a
    /// later one only adds whether it was shown. Only a receipt backfilled after a later step's line dates a message
    /// earlier: a read that merely carries an earlier day, after the Mac's zone or clock moved back, never moves it.
    private mutating func read(_ key: String, shown: Bool, copy: AttentionItem?, on day: String, backfilled: Bool) {
        if shown, shownKeys.insert(key).inserted, let id = AttentionMessageID.of(key: key), shownByMessageID[id] == nil {
            shownByMessageID[id] = key
        }
        if let first = firstDay[key] {
            guard backfilled, day < first else { return }
            keysByDay[first]?.remove(key)
        }
        firstDay[key] = day
        keysByDay[day, default: []].insert(key)
        if day < keepsItemsFrom { item[key] = nil } else if let copy { item[key] = copy }
        // Events fold in the order they were written, so a later read, or a receipt backfilled after the rest was
        // looked through, leaves the day's rest to check again.
        if !shownKeys.contains(key) { restCheckedDays.remove(day) }
    }
}

/// Message-IDs as the attention test matches them. A script item's key is its message's Message-ID, and a card from
/// another job, such as one that reads the same mail from the screen, can name one in its item key, its identity
/// evidence or its original's link. A card's own words are never searched.
enum AttentionMessageID {
    /// A script item key's Message-ID, lowercased, or nil for a key that is none, such as a message's number in its
    /// mailbox.
    static func of(itemKey: String) -> String? {
        let id = itemKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>"))).lowercased()
        return id.contains("@") ? id : nil
    }

    /// The Message-ID of a message's key: its source's id, a colon, then its item key.
    static func of(key: String) -> String? {
        key.firstIndex(of: ":").flatMap { of(itemKey: String(key[key.index(after: $0)...])) }
    }

    /// The Message-IDs cards name, lowercased, as in "Message-ID <id>" or a Gmail link that searches for
    /// "rfc822msgid:id". Anything with an "@" is taken, addresses too; they only ever match a Message-ID that is the
    /// same text.
    static func named(by cards: [MorningCard]) -> Set<String> {
        var ids: Set<String> = []
        for card in cards where !card.isSample {
            guard let tracking = card.tracking else { continue }
            for text in [tracking.itemKey, tracking.identityEvidence] + card.sources.map(\.url) where text.contains("@") || text.contains("%40") {
                let decoded = (text.removingPercentEncoding ?? text).lowercased()
                for token in decoded.split(whereSeparator: { $0.isWhitespace || "<>\"'(),;:[]?&".contains($0) }) where token.contains("@") {
                    // An id at the end of a path or a query's value, and without a sentence's full stop.
                    for part in [token, token.split(separator: "/").last ?? token, token.split(separator: "=").last ?? token] {
                        let id = part.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        if id.contains("@") { ids.insert(id) }
                    }
                }
            }
        }
        return ids
    }
}
