import Combine
import Foundation
import FamiliarContracts
import FamiliarRuntime

/// Turns saved observations into proposed work. Collection and task execution
/// remain independent: generating a card never accepts or executes its action.
@MainActor
final class CardGenerationService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?

    private let morning: MorningStore
    private let sources: CalendarStore
    private let desktop: DesktopExecutionService
    private let config: () -> Config
    private let makeClient: (Config) -> (any ConversationClient)?
    private var pending: [CardGenerationInput] = []
    private var activeRunIDs = Set<UUID>()
    private var worker: Task<Void, Never>?
    private var execution: TaskExecution?

    init(morning: MorningStore, sources: CalendarStore, desktop: DesktopExecutionService,
         config: @escaping () -> Config,
         makeClient: @escaping (Config) -> (any ConversationClient)? = ConversationBackend.make) {
        self.morning = morning
        self.sources = sources
        self.desktop = desktop
        self.config = config
        self.makeClient = makeClient
    }

    /// Restart recovery and settings changes use the same persisted receipt check
    /// as a manual request. Only saved runs without a receipt are considered.
    func start() { _ = generate() }

    @discardableResult
    func generate(runID: UUID? = nil) -> Task<Void, Never>? {
        let queued = pending.reduce(activeRunIDs) { $0.union($1.runIDs) }
        let input = CardGenerationInput.saved(in: sources, runID: runID,
            excluding: processedRunIDs.union(queued))
        if !input.runIDs.isEmpty { pending.append(input) }
        if let worker { return worker }
        guard !pending.isEmpty else {
            status = "No new saved observations to turn into cards."
            error = nil
            return nil
        }
        error = nil
        isRunning = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
            self.worker = nil
            self.isRunning = false
        }
        worker = task
        return task
    }

    func stop() {
        pending.removeAll()
        execution?.cancel()
        worker?.cancel()
        status = "Card generation stopped."
    }

    private var processedRunIDs: Set<UUID> {
        Set((morning.workspace.cardGenerations ?? []).flatMap(\.runIDs))
    }

    private var activeSourceIDs: Set<UUID> {
        Set(sources.sources.map(\.id) + sources.readingSources.map(\.id))
    }

    private func drain() async {
        while !Task.isCancelled, !pending.isEmpty {
            // A collection callback may arrive before the next queued task has
            // finished. Retain its request rather than dropping that collection.
            while desktop.isBusy || desktop.tasks.activeTask != nil {
                status = "Waiting to prepare cards after the current task."
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let settings = config()
            guard let client = makeClient(settings) else {
                error = ConversationBackend.setupMessage(config: settings)
                status = error ?? "Connect a model to prepare cards."
                return // Keep the pending input for an explicit retry/settings wake.
            }
            var input = pending.removeFirst()
            input.runIDs.removeAll { processedRunIDs.contains($0) }
            input.observations.removeAll { !input.runIDs.contains($0.runID) || !activeSourceIDs.contains($0.sourceID) }
            guard !input.runIDs.isEmpty else { continue }
            activeRunIDs = Set(input.runIDs)
            await run(input, client: client)
            activeRunIDs = []
        }
    }

    private func run(_ input: CardGenerationInput, client: any ConversationClient) async {
        var handle: TaskExecution?
        var elapsed: TimeInterval = 0
        do {
            var proposals: [CardProposal] = []
            let batches = input.candidateBatches
            for (index, observations) in batches.enumerated() {
                try Task.checkCancellation()
                let label = batches.count > 1 ? " · batch \(index + 1) of \(batches.count)" : ""
                let task = try desktop.executor.begin(TaskRequest(id: UUID(), title: "Prepare cards from collected results" + label,
                    initialStatus: "Reviewing saved observations"), onStop: { [weak self] in self?.stop() })
                handle = task
                execution = task
                status = "Preparing cards from saved observations" + label + "…"
                let submission = CardGenerationSubmission(observations: observations, rules: input.rules)
                let plan = try submission.plan(morning: morning)
                let result = try await task.run(plan, client: client, onStatus: { [weak self] in self?.status = $0 })
                elapsed = result.elapsed
                switch result.outcome {
                case .cancelled: throw CancellationError()
                case .failed(let failure): throw failure
                case .reply: break
                }
                try Task.checkCancellation()
                guard let submitted = submission.proposals else {
                    throw MorningStoreError.invalid("No structured card proposals were submitted. Your existing cards were kept.")
                }
                proposals.append(contentsOf: submitted)
                if index < batches.count - 1 {
                    task.finish(outcome: .completed,
                        text: "Reviewed observation batch \(index + 1) of \(batches.count). Cards will be saved after all batches are reviewed.",
                        elapsed: elapsed, caption: "Batch reviewed")
                    handle = nil
                }
            }
            // A source can be removed while generation is running. Its historical
            // observations remain readable but cannot recreate active cards.
            let observations = input.observations.filter { activeSourceIDs.contains($0.sourceID) }
            let keys = Set(observations.map(\.id))
            let summary = try morning.applyCardGeneration(observations: observations,
                proposals: proposals.filter { keys.contains($0.observationKey) }, runIDs: input.runIDs, at: Date())
            status = summary.message
            error = nil
            handle?.finish(outcome: .completed, text: summary.message, elapsed: elapsed, caption: "Cards updated")
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let message = cancelled ? "Card generation stopped." : error.localizedDescription
            status = message
            self.error = cancelled ? nil : message
            handle?.finish(outcome: cancelled ? .stopped : .failed, text: message, elapsed: elapsed)
        }
        execution = nil
    }
}

/// Deterministic source identity and observed facts are prepared before asking a
/// model for editorial judgment. Absence from a later read never means resolved.
/// A job's own rules for what matters, so the card step applies them (a script job reads everything that arrived).
struct SourceRules: Encodable, Equatable {
    var sourceID: UUID
    var sourceName: String
    var meaning: String
    var readingRules: String
}

struct CardGenerationInput {
    var runIDs: [UUID]
    var observations: [CardObservation]
    var rules: [SourceRules] = []
    static let candidateLimit = 80
    var candidateBatches: [[CardObservation]] {
        let candidates = observations.filter { $0.state != .resolved }
        if candidates.isEmpty { return [[]] }
        return stride(from: 0, to: candidates.count, by: Self.candidateLimit).map { start in
            Array(candidates[start..<min(start + Self.candidateLimit, candidates.count)])
        }
    }

    @MainActor static func saved(in sources: CalendarStore, runID: UUID?, excluding: Set<UUID>) -> Self {
        let active = Set(sources.sources.map(\.id) + sources.readingSources.map(\.id))
        let runs = sources.runStore.runs.filter { $0.status != .running && (runID == nil || $0.id == runID) }
        var latest: [UUID: (SourceRunRecord, SourceRunEntry, Date)] = [:]
        for run in runs {
            for entry in run.entries where active.contains(entry.sourceID) && [.complete, .partial].contains(entry.state) {
                guard let date = entry.readingSnapshot?.collectedAt ?? entry.calendarSnapshot?.collectedAt else { continue }
                if let previous = latest[entry.sourceID], previous.2 >= date { continue }
                latest[entry.sourceID] = (run, entry, date)
            }
        }
        let selected = latest.values.filter { !excluding.contains($0.0.id) }.sorted {
            $0.2 == $1.2 ? $0.1.sourceID.uuidString < $1.1.sourceID.uuidString : $0.2 > $1.2
        }
        let ids = Array(Set(selected.map { $0.0.id })).sorted { $0.uuidString < $1.uuidString }
        let rules = selected.compactMap { _, entry, _ -> SourceRules? in
            // Today's rules, if the job was changed since this run; otherwise the ones it ran with.
            guard let source = sources.readingSources.first(where: { $0.id == entry.sourceID }) ?? entry.readingSnapshot?.source,
                  calendarHasText(source.scope) else { return nil }
            return SourceRules(sourceID: source.id, sourceName: entry.sourceName, meaning: source.meaning, readingRules: source.scope)
        }
        return Self(runIDs: ids, observations: selected.flatMap { observations(run: $0.0, entry: $0.1) }, rules: rules)
    }

    private static func observations(run: SourceRunRecord, entry: SourceRunEntry) -> [CardObservation] {
        if let snapshot = entry.readingSnapshot {
            return snapshot.items.map { item in
                CardObservation(runID: run.id, sourceID: entry.sourceID,
                    itemKey: identity(item.identityKey, fallback: item.id), sourceName: entry.sourceName,
                    kind: snapshot.source.kind.rawValue, title: item.title,
                    excerpt: item.text + "\nVisible evidence: " + item.evidence,
                    url: item.url, identityEvidence: item.identityEvidence ?? "Legacy observation identifier",
                    observedAt: snapshot.collectedAt, state: item.observedState ?? .unknown,
                    stateEvidence: item.stateEvidence ?? "")
            }
        }
        if let snapshot = entry.calendarSnapshot {
            return snapshot.events.map { event in
                let zone = TimeZone(identifier: snapshot.timeZoneID) ?? .current
                let local = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)
                let details = "When: \(event.start.formatted(local)) to \(event.end.formatted(local)) (\(zone.identifier)). "
                    + "Starts: \(SourceRunJSON.timestamp(event.start)); ends: \(SourceRunJSON.timestamp(event.end)). "
                    + "Response: \(event.response.rawValue). Availability: \(event.availability.rawValue).\nVisible evidence: \(event.evidence)"
                return CardObservation(runID: run.id, sourceID: entry.sourceID,
                    itemKey: identity(event.identityKey, fallback: event.id), sourceName: entry.sourceName,
                    kind: "calendar", title: event.title, excerpt: details,
                    url: event.url.isEmpty ? (snapshot.source?.url ?? entry.calendarRequest?.source.url ?? "") : event.url,
                    identityEvidence: event.identityEvidence ?? "Legacy observation identifier",
                    observedAt: snapshot.collectedAt, state: event.observedState ?? (event.isCancelled ? .resolved : .unknown),
                    stateEvidence: event.stateEvidence ?? (event.isCancelled ? event.evidence : ""))
            }
        }
        return []
    }

    private static func identity(_ key: String?, fallback: String) -> String {
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }
}
