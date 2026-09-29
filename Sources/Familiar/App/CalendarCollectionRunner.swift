import Combine
import Foundation
import FamiliarContracts
import FamiliarRuntime

struct CalendarSourceRunResult: Identifiable, Equatable {
    typealias State = SourceRunEntry.State
    var sourceID: UUID
    var sourceName: String
    var dateLabel: String
    var state: State
    var message: String
    var id: UUID { sourceID }
}

/// An explicit, cancellable collection uses the shared desktop owner. The model
/// navigates from learned meaning; only validated tool data can become a snapshot.
@MainActor
final class CalendarCollectionRunner: ObservableObject {
    @Published private(set) var activeSourceID: UUID?
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isBatchRunning = false
    // Presentation projection of archived entries; execution never advances a second lifecycle here.
    @Published private(set) var batchResults: [CalendarSourceRunResult] = []
    @Published private(set) var currentRunID: UUID?

    /// Source planning can recheck continuing items without coupling ingestion to cards.
    var trackedItems: (UUID) -> [TrackedSourceItem] = { _ in [] }
    var onRunFinished: ((UUID) -> Void)?
    /// Runs write their story to the activity log: start, each source's result and why, and where it was saved.
    var log: (String) -> Void = { Log.info($0) }
    private var pendingFinishedRunID: UUID?

    typealias PrepareExecution = SourceCollectionTask.PrepareExecution

    private let store: CalendarStore
    private let desktop: DesktopExecutionService
    private let registry: ToolRegistry
    private let activities: NativeActivityGate
    private let config: () -> Config
    private let makeClient: (Config) -> (any ConversationClient)?
    private let prepareExecution: PrepareExecution?
    private var worker: Task<Void, Never>?
    private var execution: TaskExecution?
    private var activeID: UUID?
    private var shuttingDown = false
    private var archiveFailure: String?
    private static let removedMessage = SourceCollectionTask.removedMessage

    init(store: CalendarStore, desktop: DesktopExecutionService, registry: ToolRegistry,
         activities: NativeActivityGate, config: @escaping () -> Config,
         makeClient: @escaping (Config) -> (any ConversationClient)? = ConversationBackend.make,
         prepareExecution: PrepareExecution? = nil) {
        self.store = store
        self.desktop = desktop
        self.registry = registry
        self.activities = activities
        self.config = config
        self.makeClient = makeClient
        self.prepareExecution = prepareExecution
    }

    @discardableResult
    func collect(source: LearnedCalendarSource, day: Date, startHour: Int = 9, endHour: Int = 17) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let request = CalendarReadRequest(source: source, day: day, startHour: startHour, endHour: endHour)
        return collectOne(.calendar(request))
    }

    @discardableResult
    func collect(source: LearnedReadingSource, requestedAt: Date = Date()) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let request = ReadingReadRequest(source: source, requestedAt: requestedAt)
        return collectOne(.reading(request))
    }

    private func collectOne(_ request: SourceCollectionTask) -> Task<Void, Never>? {
        error = nil
        batchResults = []
        do { try request.validate(); try request.requireActive(in: store) }
        catch {
            let message = error.localizedDescription
            if beginArchive([request.archiveEntry(state: .failed, message: message)], origin: .single) {
                finishArchive(stopped: false)
            }
            self.error = archiveFailure ?? message
            return nil
        }
        guard beginArchive([request.archiveEntry()], origin: .single) else { return nil }
        guard let client = readyClient() else {
            let message = error ?? "Collection could not start."
            markWaitingNotRun(message)
            finishArchive(stopped: false)
            error = archiveFailure ?? message
            return nil
        }
        return start([request], client: client, batch: false)
    }

    /// Capture the saved sources and today's instant once. Each source interprets
    /// that instant in its own time zone, even if a long batch crosses midnight.
    @discardableResult
    func collectAll(day: Date = Date(), startHour: Int = 9, endHour: Int = 17) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        error = nil
        let requests: [SourceCollectionTask] = store.sources.map { .calendar(CalendarReadRequest(source: $0, day: day, startHour: startHour, endHour: endHour)) }
            + store.readingSources.map { .reading(ReadingReadRequest(source: $0, requestedAt: day)) }
        guard !requests.isEmpty else {
            batchResults = []
            error = "Teach and save a source before running all sources."
            return nil
        }
        var ready: [SourceCollectionTask] = []
        let entries = requests.map { request -> SourceRunEntry in
            do {
                try request.validate()
                ready.append(request)
                return request.archiveEntry()
            } catch {
                return request.archiveEntry(state: .failed, message: error.localizedDescription)
            }
        }
        batchResults = entries.map(Self.row)
        guard beginArchive(entries, origin: .all) else { return nil }
        guard !ready.isEmpty else {
            finishArchive(stopped: false)
            status = batchSummary(stopped: false)
            error = archiveFailure ?? "Review the saved source details before collecting."
            return nil
        }
        guard let client = readyClient() else {
            let message = error ?? "Collection could not start."
            markWaitingNotRun(message)
            finishArchive(stopped: false)
            error = archiveFailure ?? message
            status = "No sources were run."
            return nil
        }
        return start(ready, client: client, batch: true)
    }

    private var desktopAvailable: Bool {
        !desktop.isBusy && desktop.tasks.activeTask == nil && activities.current == nil
    }

    private func readyClient() -> (any ConversationClient)? {
        guard !shuttingDown else { error = "Noteling is closing."; return nil }
        guard desktopAvailable else {
            error = "Finish the current desktop task or Watch Me session before collecting this source."
            return nil
        }
        let settings = config()
        guard settings.allowControl else {
            error = "Turn on computer control in Settings to collect your sources."
            return nil
        }
        guard let client = makeClient(settings) else {
            error = ConversationBackend.setupMessage(config: settings)
            return nil
        }
        return client
    }

    private func start(_ requests: [SourceCollectionTask], client: any ConversationClient, batch: Bool) -> Task<Void, Never>? {
        do { try persistEntry(requests[0], state: .reading, message: "Reading fresh source information.") }
        catch {
            markWaitingNotRun("Collection stopped because its run history could not be saved.")
            finishArchive(stopped: false)
            self.error = archiveFailure
            return nil
        }
        isRunning = true
        isBatchRunning = batch
        // Reserve the desktop synchronously, before the worker can yield.
        let firstExecution: TaskExecution
        do { firstExecution = try begin(requests[0]) }
        catch {
            let message = error.localizedDescription
            try? persistEntry(requests[0], state: .failed, message: message)
            markWaitingNotRun(message)
            finishArchive(stopped: false)
            self.error = archiveFailure ?? message
            isRunning = false
            isBatchRunning = false
            notifyFinishedRun()
            return nil
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var stopped = false
            for (index, request) in requests.enumerated() {
                let execution: TaskExecution
                if index == 0 {
                    execution = firstExecution
                } else {
                    guard !Task.isCancelled, !self.shuttingDown else { stopped = true; break }
                    guard self.archiveFailure == nil else { break }
                    guard request.isActive(in: self.store) else {
                        do { try self.persistEntry(request, state: .notRun, message: Self.removedMessage) }
                        catch { break }
                        continue
                    }
                    guard self.desktopAvailable else {
                        self.markWaitingNotRun("Another desktop task is active. Run all sources again when it finishes.")
                        break
                    }
                    do { try self.persistEntry(request, state: .reading, message: "Reading fresh source information.") }
                    catch { break }
                    do { execution = try self.begin(request) }
                    catch {
                        try? self.persistEntry(request, state: .failed, message: error.localizedDescription)
                        break
                    }
                }
                let state = await self.run(request, client: client, execution: execution)
                if state == .stopped || Task.isCancelled || self.shuttingDown {
                    stopped = true
                    break
                }
            }
            self.markWaitingNotRun(stopped ? "Stopped before this source was read." : "This source was not read.")
            self.finishArchive(stopped: stopped)
            if batch {
                self.status = self.batchSummary(stopped: stopped)
                self.error = self.archiveFailure // Individual read failures stay attached to their source rows.
                if self.desktopAvailable {
                    self.desktop.peek.caption = self.status
                    self.desktop.peek.phase = stopped || self.batchResults.contains { $0.state == .failed || $0.state == .notRun } ? .stopped : .done
                }
            }
            if let failure = self.archiveFailure {
                self.error = failure
                self.status = failure
                if self.desktopAvailable {
                    self.desktop.peek.caption = failure
                    self.desktop.peek.phase = .stopped
                }
            }
            self.worker = nil
            self.isBatchRunning = false
            self.isRunning = false
            self.notifyFinishedRun()
        }
        worker = task
        return task
    }

    private func begin(_ request: SourceCollectionTask) throws -> TaskExecution {
        let execution = try desktop.executor.begin(request.executionRequest,
            onStop: { [weak self] in _ = self?.stopActive() })
        self.execution = execution
        activeID = request.id
        activeSourceID = request.sourceID
        status = request.executionRequest.initialStatus
        return execution
    }

    private static func row(_ entry: SourceRunEntry) -> CalendarSourceRunResult {
        return CalendarSourceRunResult(sourceID: entry.sourceID, sourceName: entry.sourceName,
            dateLabel: entry.calendarRequest.map { SourceCollectionTask.calendar($0).dateLabel } ?? entry.dateLabel,
            state: entry.state, message: entry.message)
    }

    private func beginArchive(_ entries: [SourceRunEntry], origin: SourceRunOrigin) -> Bool {
        currentRunID = nil
        pendingFinishedRunID = nil
        archiveFailure = nil
        do {
            let entries = entries.map { entry in
                var entry = entry
                if entry.state == .failed { entry.finishedAt = Date() }
                return entry
            }
            currentRunID = try store.runStore.begin(entries: entries, origin: origin).id
            log("run started: \(entries.count) source\(entries.count == 1 ? "" : "s") (\(origin.rawValue))")
            return true
        } catch {
            recordArchiveFailure(error)
            return false
        }
    }

    private func persistEntry(_ request: SourceCollectionTask, state: CalendarSourceRunResult.State,
                              message: String, evidence: CalendarCollectionEvidence? = nil) throws {
        guard let runID = currentRunID,
              var entry = store.runStore.run(id: runID)?.entries.first(where: { $0.id == request.id }) else {
            let failure = CalendarDataError.unavailable("The current source run could not be found in its archive.")
            recordArchiveFailure(failure)
            throw failure
        }
        entry.state = state
        entry.message = message
        if state == .reading { entry.startedAt = Date() }
        if state != .reading && state != .waiting { entry.finishedAt = Date() }
        if let evidence {
            entry.calendarSnapshot = evidence.snapshot
            entry.readingSnapshot = evidence.readingSnapshot
        }
        try persistEntry(entry, runID: runID)
        if state != .reading && state != .waiting {
            let took = entry.startedAt.flatMap { start in entry.finishedAt.map { " after \(Int($0.timeIntervalSince(start).rounded())) s" } } ?? ""
            log("run: “\(request.sourceName)” \(state.rawValue)\(took): \(Self.oneLine(message))")
        }
    }

    private static func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 800 ? String(flat.prefix(800)) + "…" : flat
    }

    private func persistEntry(_ entry: SourceRunEntry, runID: UUID) throws {
        do {
            let run = try store.runStore.updateEntry(runID: runID, entry: entry)
            if run.origin == .all { batchResults = run.entries.map(Self.row) }
        } catch {
            recordArchiveFailure(error)
            throw error
        }
    }

    private func recordArchiveFailure(_ failure: Error) {
        archiveFailure = "Run results could not be saved: \(failure.localizedDescription) Earlier saved results were kept."
        error = archiveFailure
        status = archiveFailure ?? "Run results could not be saved."
    }

    private func finishArchive(stopped: Bool) {
        guard let runID = currentRunID, let run = store.runStore.run(id: runID) else { return }
        let successful = archiveFailure == nil && run.entries.allSatisfy { $0.state == .complete || $0.state == .partial }
        do {
            _ = try store.runStore.finish(runID: runID, status: stopped ? .stopped : (successful ? .completed : .failed))
            let folder = store.runStore.directory(for: runID).map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Run history"
            log("run \(stopped ? "stopped" : (successful ? "completed" : "finished with problems")): saved to \(folder)")
            pendingFinishedRunID = runID
            notifyFinishedRun()
        } catch { recordArchiveFailure(error) }
    }

    private func notifyFinishedRun() {
        guard !isRunning, let runID = pendingFinishedRunID else { return }
        pendingFinishedRunID = nil
        onRunFinished?(runID)
    }

    private func markWaitingNotRun(_ message: String) {
        guard let runID = currentRunID, let run = store.runStore.run(id: runID) else { return }
        for var entry in run.entries where entry.state == .waiting {
            entry.state = .notRun
            entry.message = message
            entry.finishedAt = Date()
            do { try persistEntry(entry, runID: runID) }
            catch { break }
        }
    }

    private func batchSummary(stopped: Bool) -> String {
        let labels: [(CalendarSourceRunResult.State, String)] = [(.complete, "collected"), (.partial, "partial"), (.failed, "failed"), (.stopped, "stopped"), (.notRun, "not run")]
        let counts = labels.compactMap { state, label -> String? in
            let count = batchResults.filter { $0.state == state }.count
            return count > 0 ? "\(count) \(label)" : nil
        }
        return (stopped ? "Stopped: " : "Finished: ") + counts.joined(separator: ", ") + "."
    }

    @discardableResult
    func stopActive() -> Bool {
        guard isRunning else { return false }
        execution?.cancel()
        worker?.cancel()
        return true
    }

    func shutdown() {
        shuttingDown = true
        _ = stopActive()
    }

    func backgroundDidBegin() {
        guard activeID != nil else { return }
        desktop.executor.backgroundDidBegin()
    }

    private func run(_ request: SourceCollectionTask, client: any ConversationClient, execution: TaskExecution) async -> SourceRunEntry.State {
        let evidence = CalendarCollectionEvidence()
        var sourceRemoved = false
        var prepared = false
        let removalObservation = request.observeRemoval(in: store) {
            sourceRemoved = true
            evidence.navigated()
            // Stop only this source. Removing it does not cancel later sources.
            execution.cancel()
        }
        defer { removalObservation.cancel() }
        let plan = request.plan(desktop: desktop, registry: registry, evidence: evidence,
            prepareExecution: prepareExecution, trackedItems: trackedItems(request.sourceID), validatePermission: { [self] in
                guard !sourceRemoved else { throw CalendarDataError.invalid(Self.removedMessage) }
                try request.requireActive(in: store)
            }, didPrepare: { prepared = true })
        var outcome: BackgroundTaskOutcome = .failed
        var resultText = ""
        var coverage: CalendarCoverage?
        var elapsed: TimeInterval = 0
        do {
            try request.requireActive(in: store)
            let result = try await execution.run(plan, client: client,
                onStatus: { [weak self] text in
                    guard let self, self.activeID == request.id else { return }
                    self.status = text
                })
            elapsed = result.elapsed
            if sourceRemoved && !Task.isCancelled && !shuttingDown {
                resultText = Self.removedMessage
            } else { switch result.outcome {
            case .cancelled:
                outcome = .stopped
                resultText = "\(request.collectionLabel) stopped. The previous saved collection was kept."
            case .failed(let failure):
                resultText = failure.localizedDescription
            case .reply(let reply):
                if Task.isCancelled || shuttingDown || execution.receipt?.stopped == true {
                    outcome = .stopped
                    resultText = "\(request.collectionLabel) stopped. The previous saved collection was kept."
                } else {
                    do {
                        try request.requireActive(in: store)
                        if let saved = request.result(evidence) {
                            let state: CalendarSourceRunResult.State = saved.coverage == .partial ? .partial : .complete
                            let message = saved.coverage == .partial ? "Saved with gaps. Review the collection’s coverage notes." : "Fresh source information saved."
                            // This is the authoritative commit. No latest-only cache
                            // write may replace a prior run or claim success first.
                            try persistEntry(request, state: state, message: message, evidence: evidence)
                            coverage = saved.coverage
                            outcome = .completed
                            resultText = saved.text
                        } else {
                            resultText = request.nothingSavedMessage(reply: reply.text, rejection: evidence.lastRejection)
                        }
                    } catch {
                        resultText = "\(request.collectionLabel) could not be saved: \(error.localizedDescription)"
                    }
                }
            } }
        } catch {
            if Task.isCancelled || shuttingDown {
                outcome = .stopped
                resultText = "\(request.collectionLabel) stopped. The previous saved collection was kept."
            } else if sourceRemoved {
                resultText = Self.removedMessage
            } else {
                resultText = "\(request.collectionLabel) failed: \(error.localizedDescription)"
            }
        }
        var state: CalendarSourceRunResult.State = outcome == .completed ? (coverage == .partial ? .partial : .complete) : (outcome == .stopped ? .stopped : (sourceRemoved && !prepared ? .notRun : .failed))
        if outcome != .completed {
            do { try persistEntry(request, state: state, message: resultText) }
            catch {
                outcome = .failed
                state = .failed
                resultText = archiveFailure ?? "Run results could not be saved."
            }
        }
        self.execution = nil
        activeID = nil
        activeSourceID = nil
        error = outcome == .failed ? resultText : nil
        status = outcome == .completed ? "Collected \(request.dateLabel) from \(request.sourceName)." : resultText
        execution.finish(outcome: outcome, text: resultText, elapsed: elapsed, caption: status)
        return state
    }

}
