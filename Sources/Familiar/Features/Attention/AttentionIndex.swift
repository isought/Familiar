import Foundation

/// What the attention ledger holds, folded from its events: when the test started, which runs a card step has
/// sorted, the day each item was first read, whether it was ever shown, and each script read's own counts. Pure, so
/// the numbers can be worked out and tested without a file.
struct AttentionIndex {
    /// Items first read within this many days keep their full copy for the rest screen; older ones keep only their day.
    static let itemDays = 14

    /// One script read in a `sorted` event: what arrived and came back, for what was cut off and gaps between reads.
    struct Read: Equatable {
        /// The local day of the `sorted` event it was in.
        var day: String
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
                sortedReads[source.sourceID, default: []].append(Read(day: event.day, collectedAt: source.collectedAt, since: source.since,
                    arrived: source.arrived, returned: source.returned, truncated: source.truncated))
                sortedReads[source.sourceID]?.sort { $0.collectedAt < $1.collectedAt }
            }
            for item in sorted.items {
                if item.shown { shownKeys.insert(item.key) }
                // The earliest day wins, not the first line: a backfilled receipt can be written after a later
                // step's line while carrying its own earlier day.
                if let day = firstDay[item.key], day <= event.day { continue }
                firstDay[item.key] = event.day
                self.item[item.key] = event.day >= keepsItemsFrom ? item : nil
            }
        case .label, .implicit, .miss, .opened, .restViewed, .engaged:
            break
        }
    }
}
