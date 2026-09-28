import Foundation

/// One task-local decision, consumed by the suspended action itself. A button from an old card can never
/// answer a later request, including a later request for the same control label.
@MainActor
final class BackgroundActionApproval {
    enum Decision: Equatable { case approved, denied, timedOut, cancelled, unavailable }

    private struct Pending {
        let id: UUID
        let feed: PeekFeed
        let label: String
        let message: String?
        let context: String?
        let continuation: CheckedContinuation<Decision, Never>
    }

    private var pending: Pending?
    private var timeoutTask: Task<Void, Never>?
    var isPending: Bool { pending != nil }

    func request(label: String, on feed: PeekFeed?, timeout: TimeInterval = 120,
                 message: String? = nil, context: String? = nil) async -> Decision {
        guard !Task.isCancelled else { return .cancelled }
        guard let feed, pending == nil, feed.approvalRequestID == nil else { return .unavailable }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancelled); return }
                pending = Pending(id: id, feed: feed, label: label, message: message, context: context, continuation: continuation)
                feed.approvalRequestID = id
                feed.approvalMessage = message
                feed.approvalContext = context
                feed.onGoAhead = { [weak self] in self?.resolve(id: id, decision: .approved) }
                feed.onNotNow = { [weak self] in self?.resolve(id: id, decision: .denied) }
                feed.caption = "Waiting for approval"
                feed.phase = .confirming(label)
                timeoutTask = Task { [weak self] in
                    // Clamp externally supplied durations before converting to nanoseconds.
                    let seconds = timeout.isFinite ? min(max(0, timeout), 3_600) : 120
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                    catch { return }
                    self?.resolve(id: id, decision: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: id, decision: .cancelled) }
        }
    }

    /// Called by the controller for Stop and session teardown, even when the provider stops cooperatively.
    func cancel() {
        guard let id = pending?.id else { return }
        resolve(id: id, decision: .cancelled)
    }

    private func resolve(id: UUID, decision: Decision) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let feed = pending.feed
        let unchanged = feed.approvalRequestID == id && feed.phase == .confirming(pending.label)
            && feed.approvalMessage == pending.message && feed.approvalContext == pending.context
        let decision = unchanged ? decision : .cancelled
        if feed.approvalRequestID == id {
            feed.approvalRequestID = nil
            feed.approvalMessage = nil
            feed.approvalContext = nil
            feed.onGoAhead = nil
            feed.onNotNow = nil
            if feed.phase == .confirming(pending.label) {
                feed.phase = decision == .cancelled ? .stopped : .working
                switch decision {
                case .approved: feed.caption = pending.message == nil ? "Checking the approved control" : "Checking the approved draft"
                case .denied: feed.caption = "Approval declined"
                case .timedOut: feed.caption = "Approval timed out"
                case .cancelled: feed.caption = "Stopped"
                case .unavailable: feed.caption = "Approval unavailable"
                }
            }
        }
        pending.continuation.resume(returning: decision)
    }
}
