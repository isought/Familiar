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
    private var owner: UUID?
    private var requestTitle = "Background task"
    private let activities: NativeActivityGate
    private var lease: NativeActivityGate.Lease?

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
                 lookAtScreen: @escaping () async -> ToolResult) async throws -> PreparedExecution {
        guard owner == nil else { throw ClaudeError(message: "Another request is using desktop control.") }
        lease = try activities.acquire(.desktop)
        owner = id
        requestTitle = title
        control.reset()
        // Snapshot all request capabilities and guard labels before target resolution suspends.
        let router = try ExecutionTools.make(registry: registry, context: context, control: control,
                                             background: background, lookAtScreen: lookAtScreen)
        control.lane = background ? .background : .foreground
        control.target = target
        control.declaredIrreversible = registry.select(for: context).active.flatMap(\.irreversible)
        control.warningNoteLabels = registry.notes(for: context).filter(\.isWarning).compactMap(\.anchor.label)
        var laneNote = ""
        if background, target == nil {
            switch await TargetWindow.resolveFrontmost() {
            case .success(let target): control.target = target
            case .failure(let error):
                laneNote = "\n\nNo target window right now: \(error.localizedDescription) Call target_window to pick one before acting."
            }
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
        if let lease { activities.release(lease) }
        lease = nil
        owner = nil
        return receipt
    }
}
