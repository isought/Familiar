import Foundation
import FamiliarContracts
import FamiliarRuntime

/// Who requested work and where its progress belongs. This is independent of
/// source ingestion, morning cards, and the conversation that supplied it.
struct TaskRequest {
    enum Presentation { case task, conversation }
    let id: UUID
    let title: String
    var initialStatus = "Getting started"
    var presentation: Presentation = .task
}

/// The feature supplies instructions and capabilities; the executor owns the
/// turn. Preparation is lazy so native resources are acquired only when running.
struct TaskPlan {
    let content: [[String: Any]]
    var prepareImages = false
    let prepare: @MainActor () async throws -> PreparedExecution
}

/// Shared execution entry point. A producer reserves a job, runs its plan, then
/// validates/saves its domain result before finishing the job. No source, card,
/// file format, or success criterion is interpreted here.
@MainActor
final class TaskExecutor {
    private unowned let desktop: DesktopExecutionService
    private var executions: [UUID: TaskExecution] = [:]

    init(desktop: DesktopExecutionService) { self.desktop = desktop }

    func begin(_ request: TaskRequest, coordinator: ExecutionCoordinator? = nil,
               onStop: @escaping () -> Void = {},
               onPromoted: @escaping () -> Void = {}) throws -> TaskExecution {
        guard executions[request.id] == nil,
              request.presentation == .conversation || (!desktop.isBusy && desktop.tasks.activeTask == nil) else {
            throw ClaudeError(message: "Another request is using the task executor.")
        }
        let execution = TaskExecution(request: request, coordinator: coordinator ?? ExecutionCoordinator(),
            desktop: desktop, onStop: onStop, onPromoted: onPromoted,
            onFinish: { [weak self] in self?.executions.removeValue(forKey: request.id) })
        executions[request.id] = execution
        if request.presentation == .task { execution.present() }
        return execution
    }

    /// Native startup may replace Stop. Reconnect the whole job, regardless of
    /// whether it came from ingestion, a card, or chat.
    func backgroundDidBegin() {
        desktop.backgroundDidBegin()
        nativeDidBegin()
    }

    /// A read can initialize the controller without becoming a chat task.
    /// Reinstall Stop only for work already on the task surface.
    func nativeDidBegin() {
        guard let id = desktop.tasks.activeTask?.id else { return }
        executions[id]?.promote()
    }

    @discardableResult
    func stopActive() -> Bool {
        guard let id = desktop.tasks.activeTask?.id, let execution = executions[id] else { return false }
        execution.requestStop()
        return true
    }
}

/// One reserved execution. Domain adapters retain this handle for cancellation
/// and finalize it only after their result has been checked and persisted.
@MainActor
final class TaskExecution {
    let request: TaskRequest
    private let coordinator: ExecutionCoordinator
    private unowned let desktop: DesktopExecutionService
    private let onStop: () -> Void
    private let onPromoted: () -> Void
    private let onFinish: () -> Void
    private var previousStop: (() -> Void)?
    private var ownsPresentation = false
    private var finished = false
    private var ran = false
    private(set) var receipt: DesktopExecutionService.Receipt?

    var isPresented: Bool { desktop.tasks.isTracking(id: request.id) }

    fileprivate init(request: TaskRequest, coordinator: ExecutionCoordinator,
                     desktop: DesktopExecutionService, onStop: @escaping () -> Void,
                     onPromoted: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.request = request
        self.coordinator = coordinator
        self.desktop = desktop
        self.onStop = onStop
        self.onPromoted = onPromoted
        self.onFinish = onFinish
        previousStop = desktop.peek.onStop
    }

    fileprivate func present() {
        previousStop = desktop.peek.onStop
        ownsPresentation = true
        desktop.peek.reset()
        desktop.peek.startedAt = Date()
        desktop.peek.phase = .thinking
        desktop.peek.caption = request.initialStatus
        desktop.tasks.start(id: request.id, title: request.title)
        installStop()
    }

    fileprivate func promote() {
        guard isPresented else { return }
        if !ownsPresentation {
            ownsPresentation = true
            onPromoted()
        }
        installStop()
    }

    private func installStop() {
        desktop.peek.onStop = { [weak self] in self?.requestStop() }
    }

    fileprivate func requestStop() {
        cancel()
        onStop()
    }

    func cancel() { coordinator.cancel() }

    func run(_ plan: TaskPlan, client: any ConversationClient,
             onStatus: @escaping (String) -> Void = { _ in }) async throws -> ExecutionResult {
        guard !ran, !finished else { throw ClaudeError(message: "This task has already run.") }
        ran = true
        return try await coordinator.run(client: client, content: plan.content, prepareImages: plan.prepareImages,
            prepare: plan.prepare,
            stopNative: { [weak self] in
                guard let self else { return }
                self.desktop.stop(id: self.request.id)
            }, cleanup: { [weak self] in
                guard let self else { return }
                self.receipt = self.desktop.finish(id: self.request.id)
            }, onStatus: { [weak self] value in
                guard let self, !self.finished else { return }
                if self.isPresented { self.desktop.peek.caption = value }
                onStatus(value)
            })
    }

    /// Completion is explicit: a provider reply alone need not mean a valid
    /// ingestion result. The producer decides that before calling this method.
    func finish(outcome: BackgroundTaskOutcome, text: String, elapsed: TimeInterval,
                caption: String? = nil) {
        guard !finished else { return }
        finished = true
        if ownsPresentation {
            desktop.peek.onStop = previousStop
            desktop.peek.onGoAhead = nil
            desktop.peek.onNotNow = nil
            desktop.peek.onRaise = nil
            desktop.peek.approvalRequestID = nil
            desktop.peek.approvalMessage = nil
            desktop.peek.approvalContext = nil
            if let caption { desktop.peek.caption = caption }
            desktop.peek.phase = outcome == .completed ? .done : .stopped
        }
        desktop.tasks.finish(id: request.id, outcome: outcome, text: text, elapsed: elapsed)
        onFinish()
    }
}
