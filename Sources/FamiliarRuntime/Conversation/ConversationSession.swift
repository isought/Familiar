import Foundation

package enum ConversationSessionError: LocalizedError, Equatable {
    case turnAlreadyRunning

    package var errorDescription: String? { "A conversation turn is already running." }
}

/// Owns provider history and accepts results only from the active, current turn.
/// Clearing or changing providers invalidates results without releasing a running
/// operation; its caller must still complete or fail the turn when work finishes.
@MainActor
package final class ConversationSession {
    package struct Turn {
        package let id: UUID
        package let messages: [[String: Any]]
        fileprivate let revision: UUID
        fileprivate let userMessageIndex: Int?
    }

    package private(set) var messages: [[String: Any]] = []
    package var isRunning: Bool { activeTurnID != nil }
    private var activeTurnID: UUID?
    private var revision = UUID()

    package init() {}

    /// Adds one user turn and returns an independent provider history snapshot.
    /// CLI callers can retain image order and content by disabling API preparation.
    package func begin(content: [[String: Any]], prepareImages: Bool = true) throws -> Turn {
        guard activeTurnID == nil else { throw ConversationSessionError.turnAlreadyRunning }
        var newContent = content
        if prepareImages {
            stripOldImages()
            // Instructions precede images; the last block caches the complete turn.
            newContent = content.filter { $0["type"] as? String == "text" } + content.filter { $0["type"] as? String != "text" }
            if var last = newContent.last {
                last["cache_control"] = ["type": "ephemeral"]
                newContent[newContent.count - 1] = last
            }
        }
        messages.append(["role": "user", "content": newContent])
        trimHistory()
        let id = UUID()
        activeTurnID = id
        // Trimming removes only a prefix, so the appended user turn is last if retained.
        return Turn(id: id, messages: messages, revision: revision, userMessageIndex: messages.indices.last)
    }

    /// True while this operation may publish results or status to the current session.
    package func isCurrent(_ turn: Turn) -> Bool {
        activeTurnID == turn.id && revision == turn.revision
    }

    /// Releases this operation even when its result was invalidated. A late callback
    /// from a previously released turn cannot release a newer active operation.
    @discardableResult
    package func complete(_ turn: Turn, messages: [[String: Any]]) -> Bool {
        guard activeTurnID == turn.id else { return false }
        let accepted = isCurrent(turn)
        activeTurnID = nil
        if accepted { self.messages = messages }
        return accepted
    }

    /// Drops only the current failed user turn. An invalidated operation releases
    /// its active slot without editing history produced by clear/provider changes.
    @discardableResult
    package func fail(_ turn: Turn) -> Bool {
        guard activeTurnID == turn.id else { return false }
        let accepted = isCurrent(turn)
        activeTurnID = nil
        if accepted, let index = turn.userMessageIndex { messages.remove(at: index) }
        return accepted
    }

    package func clear() {
        revision = UUID()
        messages.removeAll()
    }

    /// Keep conversational text while discarding provider-specific tools, images,
    /// signed thinking, and cache metadata before a different provider is selected.
    package func retainTextForProviderChange() {
        revision = UUID()
        messages = messages.compactMap { message in
            guard let role = message["role"] as? String else { return nil }
            let text: String
            if let plain = message["content"] as? String {
                text = plain
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            } else { return nil }
            guard !text.isEmpty else { return nil }
            return ["role": role, "content": [["type": "text", "text": text]]]
        }
    }

    /// Replace earlier top-level user images, preserving nested tool results and
    /// assistant blocks verbatim, and remove stale user cache breakpoints.
    private func stripOldImages() {
        for i in messages.indices where messages[i]["role"] as? String == "user" {
            guard let content = messages[i]["content"] as? [[String: Any]] else { continue }
            messages[i]["content"] = content.map { block -> [String: Any] in
                if block["type"] as? String == "image" { return ["type": "text", "text": "[earlier screenshot omitted]"] }
                var b = block; b["cache_control"] = nil; return b
            }
        }
    }

    /// Keep the tail of the conversation, never splitting tool_use/tool_result pairs.
    private func trimHistory(maxMessages: Int = 24) {
        while messages.count > maxMessages {
            messages.removeFirst()
            while let first = messages.first {
                let isPlainUser = first["role"] as? String == "user" &&
                    !((first["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false)
                if isPlainUser { break }
                messages.removeFirst()
            }
        }
    }
}
