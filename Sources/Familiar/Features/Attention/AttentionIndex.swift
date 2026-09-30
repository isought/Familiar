import Foundation

/// What the attention ledger holds, folded from its events: when the test started, which runs a card step has
/// sorted, the day each item was first read, whether it was ever shown, each script read's own counts, each item's
/// label, the items marked missed, the days whose rest was looked through, and when the pack was first opened and first
/// used each day. Pure, so the numbers can be worked out and tested without a file.
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
    /// The copy of each recently read key from the `sorted` event that first held it.
    private(set) var item: [String: AttentionItem] = [:]
    /// Each script source's reads, oldest first.
    private(set) var sortedReads: [UUID: [Read]] = [:]
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
                sortedReads[source.sourceID, default: []].append(Read(day: event.day, sourceName: source.sourceName,
                    collectedAt: source.collectedAt, since: source.since, arrived: source.arrived, returned: source.returned,
                    truncated: source.truncated))
                sortedReads[source.sourceID]?.sort { $0.collectedAt < $1.collectedAt }
            }
            for item in sorted.items { read(item.key, shown: item.shown, copy: item, on: event.day, backfilled: sorted.backfilled) }
            for again in sorted.seen ?? [] { read(again.key, shown: again.shown, copy: nil, on: event.day, backfilled: sorted.backfilled) }
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

    /// A card step read `key` on `day`, with its full copy unless an earlier line holds it. The first read dates it; a
    /// later one only adds whether it was shown. Only a receipt backfilled after a later step's line dates a message
    /// earlier: a read that merely carries an earlier day, after the Mac's zone or clock moved back, never moves it.
    private mutating func read(_ key: String, shown: Bool, copy: AttentionItem?, on day: String, backfilled: Bool) {
        if shown { shownKeys.insert(key) }
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
