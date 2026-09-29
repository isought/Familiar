import Foundation
import FamiliarContracts
import FamiliarRuntime

/// Shared ownership of the app's desktop controller. Independent conversations can
/// coexist, but only one request may prepare or use this controller at a time.
@MainActor
final class DesktopExecutionService {
    struct Receipt {
        let steps: Int
        let appName: String
        let stopped: Bool
    }

    let peek: PeekFeed
    let tasks: BackgroundTaskStore
    let control: ComputerController
    lazy var executor = TaskExecutor(desktop: self)
    private var owner: UUID?
    private var requestTitle = "Background task"
    private let activities: NativeActivityGate
    private var lease: NativeActivityGate.Lease?

    var isBusy: Bool { owner != nil }

    init(control: ComputerController, activities: NativeActivityGate, enablesPeek: Bool = true) {
        self.activities = activities
        self.control = control
        let feed = PeekFeed()
        peek = feed
        tasks = BackgroundTaskStore(feed: feed)
        control.peek = enablesPeek ? peek : nil
    }

    func prepare(id: UUID, registry: ToolRegistry, context: ScreenContext?, background: Bool,
                 target: TargetWindow? = nil,
                 title: String = "Background task",
                 resolveFrontmost: Bool = true,
                 policy: ExecutionTools.Policy = .standard,
                 additionalRoutes: [ToolRoute] = [],
                 trackedItems: [TrackedSourceItem] = [],
                 onObservation: (() -> Void)? = nil, onNavigation: (() -> Void)? = nil,
                 lookAtScreen: @escaping () async -> ToolResult) async throws -> PreparedExecution {
        guard owner == nil, tasks.activeTask == nil || tasks.activeTask?.id == id else {
            throw ClaudeError(message: "Another request is using desktop control.")
        }
        lease = try activities.acquire(.desktop)
        owner = id
        requestTitle = title
        control.reset()
        switch policy {
        case .standard: control.pressRefusal = nil
        case .calendarRead: control.pressRefusal = CalendarNavigationPolicy.refusal
        case .sourceRead: control.pressRefusal = ReadingNavigationPolicy.refusal
        case .sourceFollowUp: control.pressRefusal = { ReadingNavigationPolicy.followUpRefusal($0, trackedItems: trackedItems) }
        }
        // Snapshot all request capabilities and guard labels before target resolution suspends.
        let router = try ExecutionTools.make(registry: registry, context: context, control: control,
                                             background: background, policy: policy, additionalRoutes: additionalRoutes,
                                             trackedItems: trackedItems, onObservation: onObservation, onNavigation: onNavigation,
                                             lookAtScreen: lookAtScreen)
        control.lane = background ? .background : .foreground
        control.target = target
        control.declaredIrreversible = registry.select(for: context).active.flatMap(\.irreversible)
        control.warningNoteLabels = registry.notes(for: context).filter(\.isWarning).compactMap(\.anchor.label)
        var laneNote = ""
        if background, target == nil, resolveFrontmost {
            switch await TargetWindow.resolveFrontmost() {
            case .success(let target): control.target = target
            case .failure(let error):
                laneNote = "\n\nNo target window right now: \(error.localizedDescription) Call target_window to pick one before acting."
            }
        } else if background, target == nil {
            laneNote = "\n\nThis is a queued task. No window has been selected. Call target_window to list windows and explicitly choose the application/window required by the accepted task. Never infer the task target from the person's current foreground window. If the intended target is ambiguous, stop and explain what is missing."
        }
        return PreparedExecution(system: Prompt.system + Prompt.control + (background ? Prompt.background + laneNote : ""),
                                 router: router, maxToolRounds: 40, shouldStop: { [weak control] in control?.stopped ?? true })
    }

    /// A chat request only becomes a task when the native controller attempts its first action.
    /// Ordinary questions keep their answers in chat even when background control is enabled.
    func backgroundDidBegin() {
        guard let owner, control.lane == .background else { return }
        tasks.start(id: owner, title: requestTitle)
    }

    func stop(id: UUID) {
        guard owner == id else { return }
        control.stop(reason: "you asked")
    }

    /// Capture the receipt before `end` releases the ladder, and release ownership only after cleanup.
    func finish(id: UUID) -> Receipt? {
        guard owner == id else { return nil }
        let receipt = control.summary.map { Receipt(steps: $0.steps, appName: $0.appName, stopped: control.stopped) }
        control.end()
        control.pressRefusal = nil
        if let lease { activities.release(lease) }
        lease = nil
        owner = nil
        return receipt
    }
}
