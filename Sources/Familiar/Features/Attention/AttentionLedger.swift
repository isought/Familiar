import Combine
import CryptoKit
import Foundation

/// The attention test's record on this Mac: what each card step read from script sources, which of those items it
/// showed, and what the person said and did about them. It is kept apart from cards, runs and chat, is never given
/// to a model and never goes into noteling.log. The file is read once at launch; an event joins the index only once
/// it is on disk.
@MainActor
final class AttentionLedger: ObservableObject {
    /// Bumped after every write, and once the launch read is in, so views that read the index redraw.
    @Published private(set) var revision = 0
    /// The last write failure, for the person to see. A failed write never fails the card action behind it: its events
    /// wait and go ahead of the next write, and the failure stands until they are written. An explanation's words wait
    /// in their field instead.
    @Published private(set) var error: String?
    /// The key whose explanation is being typed.
    @Published private(set) var explaining: String?
    private(set) var index: AttentionIndex
    /// False while the app reads the file in the background at launch. The screens show nothing until it is read,
    /// and what the ledger is told meanwhile waits for it, in order, keeping its own time.
    private(set) var isLoaded: Bool
    /// Events whose write failed, oldest first.
    private(set) var pending: [AttentionEvent] = []
    /// Render and tests set this to write events at other times.
    var clock: () -> Date
    /// By default it follows the Mac's zone while Noteling keeps running; each event keeps the zone it was written in.
    let timeZone: TimeZone
    /// Tests make its flush fail.
    var file: AttentionLogFile
    /// The watched store, for finding a label's card, and its last saved workspace.
    private weak var store: MorningStore?
    private var last: MorningWorkspace?
    private var watching: AnyCancellable?
    private var loading: Task<Void, Never>?
    private var waiting: [() -> Void] = []
    /// The numbers as of a revision and a day, so every view that draws them asks once and pays once.
    private var worked: (revision: Int, today: String, numbers: AttentionNumbers)?

    /// Reads the file before it returns, unless `inBackground`: the app reads it off the main thread, so a long ledger
    /// never holds up the launch. `read` reads and folds the file; tests watch which thread it runs on.
    init(directory: URL = Config.dir.appendingPathComponent("attention"), clock: @escaping () -> Date = Date.init,
         timeZone: TimeZone = .autoupdatingCurrent, inBackground: Bool = false,
         read: @escaping @Sendable (URL, Date, TimeZone) -> AttentionIndex = {
             AttentionIndex(AttentionLogFile.read($0).events, now: $1, timeZone: $2)
         }) {
        file = AttentionLogFile(url: directory.appendingPathComponent("signals.jsonl"))
        self.clock = clock
        self.timeZone = timeZone
        let url = file.url, now = clock()
        guard inBackground else {
            index = read(url, now, timeZone)
            isLoaded = true
            append([])   // a new file begins with `started`
            return
        }
        index = AttentionIndex(now: now, timeZone: timeZone)
        isLoaded = false
        loading = Task { [weak self] in
            let folded = await Task.detached(priority: .userInitiated) { read(url, now, timeZone) }.value
            self?.loaded(folded)
        }
    }

    /// Returns once the launch read is in.
    func untilLoaded() async { await loading?.value }

    /// The launch read is in: the screens can show it, a new file is started, and what waited for it runs in order.
    private func loaded(_ read: AttentionIndex) {
        index = read
        isLoaded = true
        revision += 1
        append([])
        let work = waiting
        waiting = []
        for step in work { step() }
    }

    /// Runs `work` now, or once the launch read is in: finding a message's first line, its item or whether today was
    /// already opened needs the whole file.
    private func whenLoaded(_ work: @escaping () -> Void) {
        if isLoaded { work() } else { waiting.append(work) }
    }

    /// Records what one card step read from script sources and which of those items it showed as cards: one line
    /// per receipt, written once. Calendar and screen reads are not part of the test, so a step without a script
    /// read writes nothing.
    func recordSorted(_ observations: [CardObservation], runIDs: [UUID], runs: SourceRunStore, cards: [MorningCard],
                      backfilled: Bool = false, at: Date? = nil) {
        let at = at ?? clock()
        whenLoaded { [self] in
            guard let event = sorted(observations, runIDs: runIDs, runs: runs, cards: cards, backfilled: backfilled, at: at) else { return }
            append([event])
        }
    }

    /// Records the receipts saved since the ledger started that have no line yet, such as one saved just before
    /// Noteling quit. Receipts from before the start are never pulled in, so the test starts clean. As in the card
    /// step, a job removed while its step ran was never sorted, so only jobs that are still active count. At launch it
    /// waits for the file to be read.
    func backfill(receipts: [CardGenerationRecord], sources: CalendarStore, cards: [MorningCard]) {
        whenLoaded { [self] in
            guard let startedAt = index.startedAt else { return }
            let active = Set(sources.sources.map(\.id) + sources.readingSources.map(\.id))
            let missing = receipts.filter { $0.completedAt >= startedAt && !isRecorded($0.runIDs) }
            let events = missing.compactMap { receipt in
                let observations = Self.scriptReads(runIDs: receipt.runIDs, runs: sources.runStore).flatMap {
                    CardGenerationInput.observations(run: $0.run, entry: $0.entry)
                }.filter { active.contains($0.sourceID) }
                return sorted(observations, runIDs: receipt.runIDs, runs: sources.runStore, cards: cards, backfilled: true, at: receipt.completedAt)
            }
            append(events)
        }
    }

    // MARK: - What the person did

    /// Counts what the person already does to cards as labels, from every saved change to the store, so a change
    /// made from chat counts the same as one made on the card.
    func watch(_ store: MorningStore) {
        self.store = store
        last = store.workspace
        watching = store.$workspace.dropFirst().sink { [weak self] next in self?.observe(next) }
    }

    /// `@Published` sends the new workspace before the store holds it, so this compares it with its own copy of the
    /// last one. Everything one save did goes out in one write.
    private func observe(_ next: MorningWorkspace) {
        guard let previous = last else { return }
        last = next
        let now = clock(), changes = AttentionImplicit.signals(from: previous, to: next)
        guard !changes.isEmpty else { return }
        whenLoaded { [self] in
            let events = changes.compactMap { change -> AttentionEvent? in
                guard let card = next.cards.first(where: { $0.id == change.cardID }), let item = item(for: change.key, card: card) else { return nil }
                return event(.implicit(.init(key: item.key, signal: change.signal, retracts: change.retracts, optionIndex: change.optionIndex,
                    optionMode: change.optionMode, item: item, card: AttentionCardContext(card, at: now))), at: now)
            }
            guard !events.isEmpty else { return }
            append(events)
        }
    }

    // MARK: - Labels

    /// The label as it stands: the latest thumb, else a guess from what the person did, and any explanation.
    func effective(for key: String) -> AttentionLabels.Effective { index.labels[key] ?? .init() }

    func explanation(for key: String) -> String? { index.labels[key]?.explanation }

    /// The key a card is labeled by, or nil for one the test does not read: a sample, a hand-written note, or a card
    /// from a calendar or a screen read.
    func labelKey(for card: MorningCard) -> String? {
        guard !card.isSample, let tracking = card.tracking, index.sortedReads[tracking.sourceID] != nil else { return nil }
        return tracking.key
    }

    /// A thumb only labels the item: it never changes the card, its folder or its work.
    func tapThumb(key: String, card: MorningCard?, thumb: AttentionLabels.Thumb, via: AttentionVia) {
        label(key: key, card: card, value: AttentionLabels.next(current: effective(for: key).explicit, tapped: thumb), via: via)
    }

    /// Saves why an item was worth the person's notice, or not, and ends explaining it. The words never change the label.
    /// A failed write leaves the item being explained, so the words stay in the field to save again.
    func explain(key: String, card: MorningCard?, text: String, via: AttentionVia) {
        // Trimmed again after the cut, so the file holds what the index keeps and the same words are saved once.
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AttentionLabels.explanationLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text != explanation(for: key) ?? "" {
            guard label(key: key, card: card, value: .explain, via: via, text: text) else { return }
        }
        if explaining == key { explaining = nil }
    }

    /// Records the label with the one in effect before it. An item neither read by a card step nor on a card has
    /// nothing to label. False only when the write failed. A thumb whose write failed never took effect, so tapping
    /// the same one again while it waits only tries the write again, and another one takes its place: `prior` is
    /// always the label the person saw. An explanation never waits; its words stay in the field instead. Only a
    /// screen that shows the ledger gives labels, so none comes before the launch read is in.
    @discardableResult
    func label(key: String, card: MorningCard?, value: AttentionLabelValue, via: AttentionVia, text: String? = nil) -> Bool {
        let card = card ?? store?.cards.first { $0.tracking?.key == key }
        guard let item = item(for: key, card: card) else { return true }
        let now = clock()
        let label = AttentionEvent.Label(key: item.key, value: value, weight: AttentionLabels.weight(value), prior: effective(for: item.key).state,
            text: text, via: via, item: item, card: card.map { AttentionCardContext($0, at: now) })
        if value != .explain {
            if waits(.label(label)) { return append([]) }
            pending.removeAll { if case .label(let waiting) = $0.payload { return waiting.key == item.key }; return false }
        }
        return append([event(.label(label), at: now)])
    }

    func beginExplaining(_ key: String) { explaining = key }

    func cancelExplaining() { explaining = nil }

    /// "Should have shown me" on an item a card step read, or taking it back. Tapping it again while it waits to be
    /// written only tries the write again.
    func miss(key: String, retract: Bool = false) {
        let now = clock()
        whenLoaded { [self] in
            guard var item = index.item[key] else { return }
            item.shown = index.shownKeys.contains(key)
            let miss = AttentionEvent.Miss(key: key, retract: retract, item: item)
            append(waits(.miss(miss)) ? [] : [event(.miss(miss), at: now)])
        }
    }

    /// The rest of `day`, holding `count` messages, was on screen for `seconds`. Only reaching its end makes the day's
    /// "0 missed" count, and a rest already looked through to its end is not recorded again until a new message joins it.
    func restViewed(day: String, count: Int, reachedEnd: Bool, seconds: TimeInterval) {
        let now = clock()
        whenLoaded { [self] in
            if reachedEnd, index.restCheckedDays.contains(day) { return }
            append([event(.restViewed(.init(restDay: day, count: count, reachedEnd: reachedEnd, seconds: seconds)), at: now)])
        }
    }

    // MARK: - Opening the pack

    /// The pack is on screen after an open from `trigger`, on `route` with `desk` cards to review. An open that
    /// brought it into view is recorded whatever the trigger; when it `wasOpen` already, only the day's first open
    /// that counts is. Only the launcher, the menu and the task panel count as a day the pack was opened.
    func recordOpened(_ trigger: AttentionOpenTrigger, route: MorningNavigation.Route, desk: Int, wasOpen: Bool) {
        let now = clock(), screen = AttentionOpen.route(route)
        whenLoaded { [self] in
            let countedToday = index.firstOpened[AttentionTime.day(of: now, in: timeZone)] != nil
            guard AttentionOpen.records(trigger, wasOpen: wasOpen, countedToday: countedToday) else { return }
            append([event(.opened(.init(trigger: trigger, route: screen, desk: desk)), at: now)])
        }
    }

    /// A card came on screen. Looking is neither a yes nor a no, but it is using the pack that day. Samples and
    /// hand-written notes are not part of the test.
    func cardOpened(_ card: MorningCard) {
        guard !card.isSample, let key = card.tracking?.key else { return }
        let now = clock()
        whenLoaded { [self] in
            guard let item = item(for: key, card: card) else { return }
            append([event(.engaged(.init(key: item.key, what: .cardOpened, card: AttentionCardContext(card, at: now))), at: now)])
        }
    }

    /// The item as a card step first read it. For a card the ledger has no copy of, such as one from before the ledger,
    /// it is the item as the card knows it, without mail facts. Only a source the test reads keeps the card's words; a
    /// calendar or screen read is recorded by which item it was, never by what it said. Its key can be made of the
    /// item's own words, such as a sender, a subject and a date, so it is recorded by a digest of that key.
    private func item(for key: String, card: MorningCard?) -> AttentionItem? {
        if var item = index.item[key] {
            item.shown = index.shownKeys.contains(key) || card != nil
            return item
        }
        guard let card, let tracking = card.tracking, tracking.key == key else { return nil }
        let source = card.sources.first, counted = index.sortedReads[tracking.sourceID] != nil
        let itemID = counted ? tracking.itemKey : SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return AttentionItem(key: counted ? key : CardObservation.key(sourceID: tracking.sourceID, itemKey: itemID),
            sourceID: tracking.sourceID, sourceName: tracking.sourceName, kind: source?.kind ?? "",
            runID: tracking.changes.first { $0.runID != nil }?.runID ?? tracking.lastRunID, itemID: itemID,
            readAt: tracking.firstSeenAt, subject: counted ? source?.title ?? card.title : "",
            preview: counted ? String((source?.excerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(AttentionItem.previewLimit)) : "",
            url: counted ? (source?.url).flatMap { $0.isEmpty ? nil : $0 } : nil, shown: true)
    }

    // MARK: - Writing

    /// Writes the events in one append, after any whose write failed before and starting the file first if it has no
    /// start yet, then folds them in. False only when the write failed: then they wait for the next write, and the
    /// failure is shown until they are written. An explanation never waits: its words stay in the field, to be saved
    /// again or dropped, and are never written after the person moved on. Before the launch read is in, the write
    /// waits for it.
    @discardableResult
    private func append(_ events: [AttentionEvent]) -> Bool {
        guard isLoaded else {
            waiting.append { [self] in append(events) }
            return true
        }
        keepRecentItems()
        let starts = index.startedAt == nil && !pending.contains { $0.type == .started }
        let events = (starts ? [event(.started, at: clock())] : []) + pending + events
        guard !events.isEmpty else { return true }
        do {
            try file.append(events)
        } catch {
            let error = error as NSError
            Log.info("attention log write failed (errno \(error.code))")
            // Every line reached the file and only flushing it failed: the lines read back, so they count as written.
            if error.userInfo[AttentionLogFile.linesWritten] as? Bool != true {
                pending = events.filter { event in
                    if case .label(let label) = event.payload, label.value == .explain { return false }
                    // A value JSON cannot hold fails the whole batch and never gets better, so only the rest wait.
                    return error.code != Int(EINVAL) || (try? event.line()) != nil
                }
                self.error = "Couldn’t save the attention log (error \(error.code))."
                return false
            }
        }
        pending = []
        for event in events { index.add(event) }
        error = nil
        revision += 1
        return true
    }

    private func event(_ payload: AttentionEvent.Payload, at: Date) -> AttentionEvent {
        AttentionEvent(payload, at: at, timeZone: timeZone)
    }

    /// The same thumb or miss as the latest one about its key still waiting to be written.
    private func waits(_ payload: AttentionEvent.Payload) -> Bool {
        for event in pending.reversed() {
            switch (event.payload, payload) {
            case (.label(let waiting), .label(let new)) where waiting.key == new.key:
                return waiting.value == new.value
            case (.miss(let waiting), .miss(let new)) where waiting.key == new.key:
                return waiting.retract == new.retract
            default:
                continue
            }
        }
        return false
    }

    /// Every run is in a `sorted` line, or in one waiting to be written.
    private func isRecorded(_ runIDs: [UUID]) -> Bool {
        let waiting = Set(pending.flatMap { event -> [UUID] in
            if case .sorted(let sorted) = event.payload { return sorted.runIDs }
            return []
        })
        return runIDs.allSatisfy { index.sortedRunIDs.contains($0) || waiting.contains($0) }
    }

    /// Full item copies are kept for messages first read in the last 14 days counted from today, so an app left
    /// running for weeks lets go of older ones as the days roll on.
    private func keepRecentItems() {
        index.keepItems(from: AttentionIndex.keepsItems(at: clock(), in: timeZone))
    }

    // MARK: - The numbers

    /// The numbers as the ledger stands now, in its zone. They are worked out once for each write and each day, so a
    /// screen can ask for them as often as it draws.
    var numbers: AttentionNumbers {
        let now = clock(), today = AttentionTime.day(of: now, in: timeZone)
        if let worked, worked.revision == revision, worked.today == today { return worked.numbers.at(now) }
        let numbers = AttentionNumbers(index: index, now: now, timeZone: timeZone)
        worked = (revision, today, numbers)
        return numbers
    }

    // MARK: - What a card step read

    /// The `sorted` event for one receipt, or nil when its runs are already recorded or it read no script source. A
    /// message an earlier line holds is listed by its key alone; one read twice in the receipt is listed once.
    private func sorted(_ observations: [CardObservation], runIDs: [UUID], runs: SourceRunStore, cards: [MorningCard],
                        backfilled: Bool, at: Date) -> AttentionEvent? {
        guard !isRecorded(runIDs) else { return nil }
        let shown = Set(cards.compactMap { $0.tracking?.key })
        var sources: [AttentionEvent.Sorted.Source] = [], items: [AttentionItem] = [], again: [AttentionEvent.Sorted.Seen] = []
        var listed: Set<String> = []
        for read in Self.scriptReads(runIDs: runIDs, runs: runs) {
            let observed = observations.filter { $0.runID == read.run.id && $0.sourceID == read.entry.sourceID }
            // Items the step never saw, from a source removed while it ran, were not sorted.
            guard !observed.isEmpty || read.snapshot.items.isEmpty else { continue }
            let byKey = Dictionary(read.snapshot.items.map {
                (CardObservation.key(sourceID: read.entry.sourceID, itemKey: CardGenerationInput.identity($0.identityKey, fallback: $0.id)), $0)
            }, uniquingKeysWith: { first, _ in first })
            for observation in observed {
                guard let item = byKey[observation.id], listed.insert(observation.id).inserted else { continue }
                let wasShown = shown.contains(observation.id)
                guard index.firstDay[observation.id] == nil else {
                    again.append(.init(key: observation.id, shown: wasShown))
                    continue
                }
                items.append(attentionItem(item, observation: observation, script: read.snapshot.source.script, shown: wasShown))
            }
            let counts = read.snapshot.scriptRead
            sources.append(.init(sourceID: read.entry.sourceID, sourceName: read.entry.sourceName, script: read.snapshot.source.script ?? "",
                runID: read.run.id, collectedAt: read.snapshot.collectedAt, since: counts?.since,
                arrived: counts?.arrived ?? read.snapshot.items.count, returned: counts?.returned ?? read.snapshot.items.count,
                truncated: counts?.truncated ?? false))
        }
        guard !sources.isEmpty else { return nil }
        return event(.sorted(.init(runIDs: runIDs, backfilled: backfilled, sources: sources, items: items, seen: again.isEmpty ? nil : again)), at: at)
    }

    /// Each script source's read in a card step: its latest complete or partial one among the step's runs, which is
    /// the one the step took.
    private static func scriptReads(runIDs: [UUID], runs: SourceRunStore)
        -> [(run: SourceRunRecord, entry: SourceRunEntry, snapshot: ReadingSnapshot)] {
        var latest: [UUID: (run: SourceRunRecord, entry: SourceRunEntry, snapshot: ReadingSnapshot)] = [:]
        for run in runIDs.compactMap(runs.run(id:)) {
            for entry in run.entries where [.complete, .partial].contains(entry.state) {
                guard let snapshot = entry.readingSnapshot, snapshot.source.readsThroughScript else { continue }
                if let previous = latest[entry.sourceID], previous.snapshot.collectedAt >= snapshot.collectedAt { continue }
                latest[entry.sourceID] = (run, entry, snapshot)
            }
        }
        return latest.values.sorted {
            $0.snapshot.collectedAt == $1.snapshot.collectedAt
                ? $0.entry.sourceID.uuidString < $1.entry.sourceID.uuidString : $0.snapshot.collectedAt > $1.snapshot.collectedAt
        }
    }

    /// The item with its mail facts as data. Hours and weekdays are local to the ledger's zone.
    private func attentionItem(_ item: ReadingItem, observation: CardObservation, script: String?, shown: Bool) -> AttentionItem {
        let mail = item.mail
        let received = mail?.received.flatMap(AttentionTime.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // With mail facts, the text is one line of them, then the preview; a row that brought its own text keeps all of it.
        let preview = mail == nil ? Substring(item.text) : item.text.firstIndex(of: "\n").map { item.text[item.text.index(after: $0)...] } ?? ""
        return AttentionItem(key: observation.id, sourceID: observation.sourceID, sourceName: observation.sourceName,
            kind: observation.kind, script: script, runID: observation.runID, itemID: item.id, readAt: observation.observedAt,
            subject: item.title, from: mail.flatMap { $0.from.isEmpty ? nil : $0.from }, fromName: mail?.name,
            address: mail?.address, domain: mail?.domain, tab: mail?.tab, bulk: mail?.bulk, important: mail?.important,
            starred: mail?.starred, unread: mail?.unread, received: received,
            receivedHour: received.map { calendar.component(.hour, from: $0) },
            receivedWeekday: received.map { calendar.component(.weekday, from: $0) },
            ageHours: received.map { observation.observedAt.timeIntervalSince($0) / 3_600 },
            preview: String(preview.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AttentionItem.previewLimit)),
            url: item.url.isEmpty ? nil : item.url, shown: shown)
    }
}

/// Which opens of the pack say the person chose to look at it. Nothing opens it on its own or sends a notification,
/// so every open that counts is unforced.
enum AttentionOpen {
    /// An open that brings the pack into view is recorded; moving to another screen of an open pack is the same
    /// visit. The pack can stay on screen overnight, so the first open that counts on a day is recorded even when the
    /// pack was already open.
    static func records(_ trigger: AttentionOpenTrigger, wasOpen: Bool, countedToday: Bool) -> Bool {
        !wasOpen || trigger.counts && !countedToday
    }

    /// An open asked for while a desktop grant hides the pack, recorded once the pack shows again.
    struct Held: Equatable {
        var trigger: AttentionOpenTrigger
        var wasOpen: Bool
    }

    /// The open to hold after another request during the same grant. A later open wins unless only the held one
    /// counts; whether the pack was open is from before the first request.
    static func hold(_ trigger: AttentionOpenTrigger, wasOpen: Bool, over held: Held?) -> Held {
        guard let held else { return Held(trigger: trigger, wasOpen: wasOpen) }
        return held.trigger.counts && !trigger.counts ? held : Held(trigger: trigger, wasOpen: held.wasOpen)
    }

    /// The screen the pack opened on, by a short name.
    static func route(_ route: MorningNavigation.Route) -> String {
        switch route {
        case .folders: return "folders"
        case .card: return "card"
        case .people: return "people"
        case .sources: return "sources"
        case .sourceRun: return "sourceRun"
        default: return "other"
        }
    }
}

extension AttentionOpenTrigger {
    /// The launcher, the menu and the task panel are the person opening the pack. Chat, Who's Who and a run open it
    /// on the way to something else, so those opens are recorded but never count as a day opened.
    var counts: Bool {
        switch self {
        case .launcher, .menu, .taskPanel: return true
        case .chat, .people, .run: return false
        }
    }
}
