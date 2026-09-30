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
    let keepsItemsFrom: String

    init(_ events: [AttentionEvent] = [], now: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let cutoff = calendar.date(byAdding: .day, value: -Self.itemDays, to: now) ?? now
        self.init(events, keepsItemsFrom: AttentionTime.day(of: cutoff, in: timeZone))
    }

    init(_ events: [AttentionEvent] = [], keepsItemsFrom day: String) {
        keepsItemsFrom = day
        for event in events { add(event) }
    }

    mutating func add(_ event: AttentionEvent) {
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
            for item in sorted.items {
                if item.shown { shownKeys.insert(item.key) }
                // The earliest day wins, not the first line: a backfilled receipt can be written after a later
                // step's line while carrying its own earlier day.
                if let day = firstDay[item.key], day <= event.day { continue }
                firstDay[item.key] = event.day
                self.item[item.key] = event.day >= keepsItemsFrom ? item : nil
                // Events fold in the order they were written, so a later read, or a receipt backfilled after the rest
                // was looked through, leaves the day's rest to check again.
                if !shownKeys.contains(item.key) { restCheckedDays.remove(event.day) }
            }
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
}
