import Combine
import Foundation
import FamiliarContracts

/// Owns a recording from capture through review. The app decides permissions, navigation, and how events read on screen.
@MainActor
final class WatchLearnSession: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, stopping, waitingForDelivery, awaitingPurpose, awaitingContext, summarizing, review, failed, saving
    }

    enum FailureStage { case summarize, keep }

    enum Event {
        case started
        case stopped
        case purposeRequested(Recording)
        case contextRequested(Recording)
        case emptyRecording
        case draftReady(draft: PackDraft, recording: Recording, elapsed: TimeInterval)
        case kept(draft: PackDraft, files: [URL])
        case failed(stage: FailureStage, error: Error)
        case discarded(savedFiles: [URL])
    }

    /// Side effects are supplied by the app adapter. Tests use local fixtures without starting capture or contacting a model.
    struct Operations {
        var start: (@escaping (Int) -> Void) throws -> Void
        var stop: () async -> Recording
        var abandon: () -> Void
        var summarize: (Recording, String?, @escaping (String) -> Void) async throws -> PackDraft
        var write: (PackDraft) throws -> [URL]
        var reload: () async throws -> Void
        var saveSource: (PackDraft) throws -> Void = { _ in }
        var saveMeta: (Recording) throws -> Void = { try $0.saveMeta() }
        var deleteRecording: (Recording) -> Void = { try? FileManager.default.removeItem(at: $0.dir) }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pendingRecording: Recording?
    @Published private(set) var pendingDraft: PackDraft?
    @Published private(set) var status = ""
    @Published private(set) var clickCount = 0
    @Published private(set) var isTeachingSource = false
    var isTeachingCalendar: Bool { isTeachingSource } // Compatibility with the original calendar entry point.
    var onEvent: ((Event) -> Void)?

    var watching: Bool { phase == .recording || phase == .stopping }
    var stopping: Bool { phase == .stopping }
    var busy: Bool { phase == .summarizing || phase == .saving }
    var awaitingPurpose: Bool { phase == .awaitingPurpose }
    var awaitingContext: Bool { phase == .awaitingContext }
    var draftFailed: Bool { phase == .failed }
    var hasPendingReview: Bool { pendingRecording != nil || pendingDraft != nil }

    private let operations: Operations
    private var generation = 0
    private var purposeDeliveryPaused = false
    private var stopTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var keepTask: Task<Void, Never>?
    // Reloading or saving a source can fail after writing succeeded. Retry must not duplicate workflow files.
    private var writtenFiles: [URL]?

    init(operations: Operations) { self.operations = operations }

    /// The caller handles permission checks before starting, and presents an existing review when this returns false.
    @discardableResult
    func start(calendar: Bool = false, source: Bool = false) throws -> Bool {
        guard phase == .idle, !hasPendingReview, stopTask == nil else { return false }
        generation += 1
        let token = generation
        clickCount = 0
        try operations.start { [weak self] count in
            guard let self, self.generation == token else { return }
            self.clickCount = count
        }
        isTeachingSource = calendar || source
        status = ""
        phase = .recording
        onEvent?(.started)
        return true
    }

    /// Retain the draining stop until it returns, even after cancellation, so a late recording is always cleaned up.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard phase == .recording else { return nil }
        phase = .stopping
        let token = generation
        let operations = self.operations
        let task = Task { [weak self] in
            let recording = await operations.stop()
            guard let self else { operations.deleteRecording(recording); return }
            self.stopTask = nil
            guard self.generation == token else {
                operations.deleteRecording(recording)
                if self.phase == .stopping { self.phase = .idle }
                return
            }
            self.pendingRecording = recording
            self.phase = .waitingForDelivery
            self.onEvent?(.stopped)
            self.deliverPurposeIfReady()
        }
        stopTask = task
        return task
    }

    /// Chat can defer presentation while its reply is in flight; recording ownership never moves to the chat feature.
    func setPurposeDeliveryPaused(_ paused: Bool) {
        purposeDeliveryPaused = paused
        if !paused { deliverPurposeIfReady() }
    }

    private func deliverPurposeIfReady() {
        guard !purposeDeliveryPaused, phase == .waitingForDelivery, let recording = pendingRecording else { return }
        guard recording.events.contains(where: { $0.kind != "scene" }) else {
            operations.deleteRecording(recording)
            pendingRecording = nil
            isTeachingSource = false
            phase = .idle
            onEvent?(.emptyRecording)
            return
        }
        phase = .awaitingPurpose
        onEvent?(.purposeRequested(recording))
    }

    /// The description advances to optional context without contacting a provider.
    @discardableResult
    func submitDescription(_ description: String?) -> Bool {
        guard phase == .awaitingPurpose, var recording = pendingRecording else { return false }
        recording.meta.purpose = Self.optionalText(description)
        do { try operations.saveMeta(recording) }
        catch { onEvent?(.failed(stage: .summarize, error: error)); return false }
        pendingRecording = recording
        phase = .awaitingContext
        onEvent?(.contextRequested(recording))
        return true
    }

    /// Both inputs now belong to the same recording and the same generation request.
    @discardableResult
    func submitContext(_ context: String?) -> Task<Void, Never>? {
        guard phase == .awaitingContext, var recording = pendingRecording else { return nil }
        recording.meta.context = Self.optionalText(context)
        do { try operations.saveMeta(recording) }
        catch { onEvent?(.failed(stage: .summarize, error: error)); return nil }
        pendingRecording = recording
        return summarize(purpose: recording.meta.purpose)
    }

    private static func optionalText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    func summarize(purpose: String?) -> Task<Void, Never>? {
        guard !busy, !watching, phase != .waitingForDelivery, var recording = pendingRecording else { return nil }
        if let purpose, !purpose.isEmpty, recording.meta.purpose != purpose {
            recording.meta.purpose = purpose
            try? operations.saveMeta(recording)
        }
        generation += 1
        let token = generation
        pendingRecording = recording
        pendingDraft = nil
        writtenFiles = nil
        phase = .summarizing
        status = "Writing it up…"
        let operations = self.operations
        let summaryPurpose = isTeachingSource ? Self.sourcePurpose(purpose) : purpose
        let task = Task { [weak self] in
            guard self?.generation == token, !Task.isCancelled else { return }
            let started = Date()
            let report: (String) -> Void = { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.phase == .summarizing else { return }
                    self.status = value == "Thinking…" ? "Writing it up…" : value
                }
            }
            let result: Result<PackDraft, Error>
            do { result = .success(try await operations.summarize(recording, summaryPurpose, report)) }
            catch { result = .failure(error) }
            guard let self, self.generation == token else { return }
            self.summaryTask = nil
            switch result {
            case .success(let draft):
                self.pendingDraft = draft
                self.phase = draft.parsed ? .review : .failed
                let elapsed = Date().timeIntervalSince(started)
                self.status = String(format: "draft in %.0fs · confidence %.0f%%", elapsed, draft.confidence * 100)
                self.onEvent?(.draftReady(draft: draft, recording: recording, elapsed: elapsed))
            case .failure(let error):
                self.phase = .failed
                self.status = ""
                self.onEvent?(.failed(stage: .summarize, error: error))
            }
        }
        summaryTask = task
        return task
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard draftFailed else { return nil }
        return summarize(purpose: pendingRecording?.meta.purpose)
    }

    func keep() async {
        guard !busy, let draft = pendingDraft, draft.parsed, let recording = pendingRecording else { return }
        guard !isTeachingSource || draft.calendarSource != nil || draft.readingSource != nil else {
            onEvent?(.failed(stage: .keep, error: ClaudeError(message: "No reading source was established, so nothing has been saved. Show the source address, account and a bounded view of the information to read. Discard this draft and teach it again; ordinary action workflows cannot be run as reading sources.")))
            return
        }
        phase = .saving
        status = "Saving…"
        let token = generation
        let operations = self.operations
        let task = Task { [weak self] in
            guard let self, self.generation == token else { return }
            do {
                let files: [URL]
                if let written = self.writtenFiles { files = written }
                else {
                    files = try operations.write(draft)
                    self.writtenFiles = files
                }
                try await operations.reload()
                guard self.generation == token else { return }
                try operations.saveSource(draft)
                operations.deleteRecording(recording)
                self.pendingRecording = nil
                self.pendingDraft = nil
                self.writtenFiles = nil
                self.isTeachingSource = false
                self.phase = .idle
                self.status = ""
                self.keepTask = nil
                self.onEvent?(.kept(draft: draft, files: files))
            } catch {
                guard self.generation == token else { return }
                self.phase = .review
                self.status = ""
                self.keepTask = nil
                self.onEvent?(.failed(stage: .keep, error: error))
            }
        }
        keepTask = task
        await task.value
    }

    func discard() {
        guard phase != .recording else { return }
        let savedFiles = writtenFiles ?? []
        clearPending()
        onEvent?(.discarded(savedFiles: savedFiles))
    }

    /// Clearing the pad forgets an unfinished review, but leaves an actively running recording alone.
    func clear() {
        guard phase != .recording else { return }
        clearPending()
    }

    /// Quit/feature teardown: stop capture and forget any review. A draining stop cleans its result when it returns.
    func abort() {
        operations.abandon()
        clearPending()
    }

    private func clearPending() {
        generation += 1
        summaryTask?.cancel()
        summaryTask = nil
        keepTask?.cancel()
        keepTask = nil
        stopTask?.cancel()
        if let recording = pendingRecording { operations.deleteRecording(recording) }
        pendingRecording = nil
        pendingDraft = nil
        writtenFiles = nil
        isTeachingSource = false
        status = ""
        clickCount = 0
        phase = stopTask == nil ? .idle : .stopping
    }

    static func sourcePurpose(_ purpose: String?) -> String {
        let intent = "Teach Familiar a source to read from Run all sources. Use reading_source for mail or web information, or calendar_source for a calendar. Learn the demonstrated application, address, account, bounded scope, navigation and completion checks. Keep the source's meaning separate from reading rules in scope. Preserve the user's explicit time range, unread status, exclusions and stopping limit, even when the demonstration shows a broader view. Keep relative rules such as the last 2 days relative to each future run, not fixed to the demonstration date. For mail without explicit rules, use only the demonstrated first visible page; do not infer permission to scan the whole mailbox. Keep anything not shown unknown, and flag any requested filter whose controls were not demonstrated as uncertain. If the recorded URL is stale but a supplied screenshot visibly shows the address, cite that exact screenshot evidence in url_evidence and require review. Demonstrated messages, dates and events are examples, never current results of a future read. Do not turn sending, editing or other action workflows into reading sources."
        guard let purpose, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return intent }
        return intent + "\n\nUser's description: " + purpose
    }

    static func calendarPurpose(_ purpose: String?) -> String { sourcePurpose(purpose) }
}
