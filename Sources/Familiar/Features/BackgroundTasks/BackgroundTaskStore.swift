import AppKit
import Combine

enum BackgroundTaskOutcome: Equatable {
    case completed, stopped, failed

    var label: String {
        switch self {
        case .completed: return "Result ready"
        case .stopped: return "Stopped"
        case .failed: return "Couldn’t finish"
        }
    }
}

struct ActiveBackgroundTask: Identifiable {
    let id: UUID
    let title: String
    let startedAt: Date
}

/// A completed task owns its last view of the target. Resetting the live feed for a new run must not erase it.
struct BackgroundTaskRecord: Identifiable {
    let id: UUID
    let title: String
    let outcome: BackgroundTaskOutcome
    let text: String
    let startedAt: Date
    let finishedAt: Date
    let elapsed: TimeInterval
    let frame: CGImage?
    let appName: String
    let windowTitle: String
    let step: Int
    let caption: String

    var metaLine: String {
        var parts = [appName, windowTitle].filter { !$0.isEmpty }
        if step > 0 { parts.append("\(step) steps") }
        return parts.joined(separator: " · ")
    }
}

/// Presentation and results for execution are independent of the conversation that started the task.
/// History is intentionally session-only; a bounded number of screenshots is retained in memory.
@MainActor final class BackgroundTaskStore: ObservableObject {
    let feed: PeekFeed
    @Published private(set) var activeTask: ActiveBackgroundTask?
    @Published private(set) var history: [BackgroundTaskRecord] = []
    @Published private(set) var selectedTaskID: UUID?
    @Published private(set) var isVisible = false
    @Published private(set) var isExpanded = false
    /// Persisted morning work is projected here without retaining another copy of its screenshots.
    @Published private(set) var morningWork: [MorningWorkItem] = []
    @Published private(set) var queueMessage: String?

    private let historyLimit = 20
    private var phaseObservation: AnyCancellable?
    private let explicitOpen = PassthroughSubject<Void, Never>()

    /// A transient user intent, separate from visibility. Automatic progress and approvals never emit it.
    var explicitOpenRequests: AnyPublisher<Void, Never> { explicitOpen.eraseToAnyPublisher() }

    init(feed: PeekFeed) {
        self.feed = feed
        phaseObservation = feed.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self, let task = self.activeTask else { return }
            switch phase {
            case .asking, .confirming:
                // A new decision deserves a visible affordance, but does not force open the preview.
                // Repeated frames/captions cannot reopen it after the user dismisses the same request.
                self.selectedTaskID = task.id
                self.isVisible = true
            default: break
            }
        }
    }

    var selectedRecord: BackgroundTaskRecord? {
        history.first { $0.id == selectedTaskID }
    }

    var isShowingActiveTask: Bool {
        activeTask != nil && selectedTaskID == activeTask?.id
    }

    var hasTasks: Bool { activeTask != nil || !history.isEmpty || !morningWork.isEmpty }
    var queuedCount: Int { morningWork.filter { $0.status == .queued }.count }
    var selectedMorningWork: MorningWorkItem? { morningWork.first { $0.id == selectedTaskID } }

    /// A saved handoff reveals only the compact receipt. It never requests keyboard focus.
    func syncMorning(_ work: [MorningWorkItem], message: String?) {
        let oldIDs = Set(morningWork.map(\.id))
        let arrived = work.contains { $0.status == .queued && !oldIDs.contains($0.id) }
        morningWork = work
        queueMessage = message
        if arrived {
            if activeTask == nil { selectedTaskID = work.first(where: { $0.status == .queued })?.id }
            if !isVisible { isExpanded = false }
            isVisible = true
        }
    }

    func isTracking(id: UUID) -> Bool { activeTask?.id == id }

    /// Called when native background execution actually begins, not when a prompt is merely submitted.
    func start(id: UUID, title: String) {
        guard activeTask == nil, !history.contains(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        activeTask = ActiveBackgroundTask(id: id, title: trimmed.isEmpty ? "Background task" : trimmed,
                                          startedAt: feed.startedAt ?? Date())
        selectedTaskID = id
        isExpanded = false
        isVisible = true
    }

    func finish(id: UUID, outcome: BackgroundTaskOutcome, text: String, elapsed: TimeInterval) {
        guard let task = activeTask, task.id == id else { return }
        let record = BackgroundTaskRecord(
            id: task.id, title: task.title, outcome: outcome, text: text,
            startedAt: task.startedAt, finishedAt: Date(), elapsed: max(0, elapsed),
            frame: thumbnail(feed.frame), appName: feed.appName, windowTitle: feed.windowTitle,
            step: feed.step, caption: feed.caption
        )
        history.insert(record, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        activeTask = nil
        if selectedTaskID == nil || (selectedTaskID != id && selectedRecord == nil) {
            selectedTaskID = id
        }
        // Finishing does not undo the user's collapse or dismissal.
    }

    func show() {
        guard hasTasks else { return }
        if selectedTaskID == nil { selectedTaskID = activeTask?.id ?? history.first?.id ?? morningWork.last?.id }
        isVisible = true
        explicitOpen.send()
    }

    func showLatest() {
        selectedTaskID = activeTask?.id ?? history.first?.id ?? morningWork.last?.id
        show()
    }

    func dismiss() { isVisible = false }

    func toggleExpanded() {
        guard hasTasks else { return }
        isExpanded.toggle()
        if isExpanded { explicitOpen.send() }
    }

    func selectTask(id: UUID) {
        guard activeTask?.id == id || history.contains(where: { $0.id == id }) || morningWork.contains(where: { $0.id == id }) else { return }
        selectedTaskID = id
        isExpanded = true
        isVisible = true
        explicitOpen.send()
    }

    /// A dock preview never needs to retain twenty full-resolution desktop captures.
    private func thumbnail(_ image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        let longestEdge = max(image.width, image.height)
        guard longestEdge > 720 else { return image }
        let scale = 720.0 / Double(longestEdge)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
