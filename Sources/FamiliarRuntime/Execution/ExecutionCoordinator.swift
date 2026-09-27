import Foundation
import FamiliarContracts

/// Provider-independent preparation supplied by the application, including its native tool adapters.
package struct PreparedExecution {
    package let system: String
    package let router: ToolRouter
    package let maxToolRounds: Int
    package let shouldStop: () -> Bool

    package init(system: String, router: ToolRouter, maxToolRounds: Int = 8,
                 shouldStop: @escaping () -> Bool = { false }) {
        self.system = system
        self.router = router
        self.maxToolRounds = maxToolRounds
        self.shouldStop = shouldStop
    }
}

package struct ExecutionUpdate {
    package enum Phase: Equatable { case preparing, running, stopping, finished }
    package let id: UUID
    package let phase: Phase
    package let status: String
}

package struct ExecutionResult {
    package enum Outcome {
        case reply(ClaudeReply)
        case cancelled
        case failed(Error)
    }
    package let outcome: Outcome
    package let accepted: Bool
    package let elapsed: TimeInterval
}

/// Owns one conversation's in-flight work. Views do not own its task or history.
/// Separate conversations use separate coordinators; native resource sharing stays with the app.
@MainActor
package final class ExecutionCoordinator {
    package let conversation: ConversationSession
    package private(set) var update: ExecutionUpdate?
    package var onUpdate: ((ExecutionUpdate) -> Void)?
    package var isRunning: Bool { activeID != nil }
    private var activeID: UUID?
    private var task: Task<ExecutionResult, Never>?
    private var stopNative: (() -> Void)?

    package init(conversation: ConversationSession? = nil) {
        self.conversation = conversation ?? ConversationSession()
    }

    /// `cleanup` runs once, including on preparation failure and cancellation, before the terminal update.
    /// Native adapters may collect receipts there before releasing their resources.
    package func run(client: any ConversationClient, content: [[String: Any]], prepareImages: Bool = true,
                     prepare: @escaping @MainActor () async throws -> PreparedExecution,
                     stopNative: @escaping @MainActor () -> Void = {},
                     cleanup: @escaping @MainActor () -> Void = {},
                     onStatus: @escaping @MainActor (String) -> Void = { _ in }) async throws -> ExecutionResult {
        guard !isRunning else { throw ConversationSessionError.turnAlreadyRunning }
        let turn = try conversation.begin(content: content, prepareImages: prepareImages)
        activeID = turn.id
        self.stopNative = stopNative
        publish(turn.id, .preparing, "Thinking…")
        let started = Date()
        let work = Task { @MainActor in
            let outcome: ExecutionResult.Outcome
            let accepted: Bool
            let tools = CancellationToolJournal()
            do {
                try Task.checkCancellation()
                let plan = try await prepare()
                try Task.checkCancellation()
                let oldStop = client.shouldStop
                let oldBudget = client.maxToolRounds
                client.shouldStop = { Task.isCancelled || plan.shouldStop() }
                client.maxToolRounds = plan.maxToolRounds
                defer { client.shouldStop = oldStop; client.maxToolRounds = oldBudget }
                if self.conversation.isCurrent(turn) { self.publish(turn.id, .running, "Thinking…") }
                // An update subscriber can synchronously request Stop.
                try Task.checkCancellation()
                var messages = turn.messages
                let reply = try await client.converse(system: plan.system, tools: plan.router.definitions,
                                                       messages: &messages, executor: { name, input, toolset in
                    let attempt = tools.begin(name: name, input: input, toolset: toolset)
                    let result = await plan.router.execute(name, input, toolset: toolset)
                    tools.finish(attempt, result: result)
                    return result
                },
                                                       onStatus: { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.activeID == turn.id, self.conversation.isCurrent(turn),
                              self.update?.phase == .running else { return }
                        self.publish(turn.id, .running, status)
                        onStatus(status)
                    }
                })
                try Task.checkCancellation()
                accepted = self.conversation.complete(turn, messages: messages)
                outcome = .reply(reply)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // A provider may have left an unmatched tool_use in its local history.
                    // Retain the valid starting turn and our own account of tool outcomes.
                    accepted = self.conversation.complete(turn, messages: turn.messages + [tools.stoppedMessage()])
                    outcome = .cancelled
                } else {
                    accepted = self.conversation.fail(turn)
                    outcome = .failed(error)
                }
            }
            cleanup()
            let result = ExecutionResult(outcome: outcome, accepted: accepted, elapsed: Date().timeIntervalSince(started))
            return result
        }
        task = work
        // A subscriber may request Stop synchronously in response to the preparing update.
        if Task.isCancelled { cancel() }
        if update?.phase == .stopping { work.cancel() }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.activeID == turn.id else { return }
                self?.cancel()
            }
        }
        task = nil
        self.stopNative = nil
        activeID = nil
        publish(turn.id, .finished, "")
        return result
    }

    package func cancel() {
        guard let id = activeID, update?.phase != .stopping else { return }
        publish(id, .stopping, "Stopping…")
        // Resolve native approval continuations before waiting for cancellation to unwind the task.
        stopNative?()
        task?.cancel()
    }

    private func publish(_ id: UUID, _ phase: ExecutionUpdate.Phase, _ status: String) {
        update = ExecutionUpdate(id: id, phase: phase, status: status)
        onUpdate?(update!)
    }
}

/// Records only the execution boundary, without interpreting a provider's partial
/// conversation. Actor isolation also permits providers that dispatch tools in tasks.
@MainActor
private final class CancellationToolJournal {
    private struct Attempt {
        let name: String
        let input: String
        var result: String?
    }

    private var attempts: [Attempt] = []

    func begin(name: String, input: [String: Any], toolset: String?) -> Int {
        let qualifiedName = toolset.map { "\($0).\(name)" } ?? name
        attempts.append(Attempt(name: preview(qualifiedName, limit: 160), input: jsonPreview(input, limit: 600)))
        return attempts.count - 1
    }

    func finish(_ index: Int, result: ToolResult) {
        attempts[index].result = (result.isError ? "Returned error: " : "Returned result: ") + contentPreview(result.content)
    }

    func stoppedMessage() -> [String: Any] {
        let text: String
        if attempts.isEmpty {
            text = "The request was stopped. No tools were attempted."
        } else {
            let lines = attempts.enumerated().map { index, attempt in
                let result = attempt.result ?? "Outcome unknown: this call had not returned when the request stopped. Check the current state before retrying it."
                return "\(index + 1). \(attempt.name)\nInput: \(attempt.input)\n\(result)"
            }
            text = "The request was stopped before it finished. Recorded tool activity:\n\n" + lines.joined(separator: "\n\n")
        }
        return ["role": "assistant", "content": [["type": "text", "text": text]]]
    }

    private func contentPreview(_ content: Any) -> String {
        if let text = content as? String { return preview(text, limit: 2_000) }
        if let blocks = content as? [[String: Any]] {
            let descriptions = blocks.map { block -> String in
                if let text = block["text"] as? String { return text }
                if block["type"] as? String == "image" { return "[Image returned; image data omitted from this stopped-request summary.]" }
                return "[\(block["type"] as? String ?? "Non-text") content returned.]"
            }
            return preview(descriptions.joined(separator: "\n"), limit: 2_000)
        }
        return jsonPreview(content, limit: 2_000)
    }

    private func jsonPreview(_ value: Any, limit: Int) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "[Non-text content omitted.]" }
        return preview(text, limit: limit)
    }

    private func preview(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "… [truncated]" : text
    }
}
