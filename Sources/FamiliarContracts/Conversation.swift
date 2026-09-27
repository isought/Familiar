import Foundation

/// Both connections provide the same conversation and tool-execution boundary.
///
/// The wire-shaped dictionaries are transitional: preserve provider content blocks,
/// including signed thinking and image payloads, until a typed representation can
/// replace them without changing conversation replay or tool behavior.
package protocol ConversationClient: AnyObject {
    var effort: String { get set }
    var maxTokens: Int { get set }
    var maxToolRounds: Int { get set }
    var shouldStop: () -> Bool { get set }

    func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                  executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply
}

package struct ClaudeError: LocalizedError {
    package let message: String
    package var errorDescription: String? { message }

    package init(message: String) { self.message = message }
}

package struct ClaudeReply {
    package let text: String
    package let inputTokens: Int
    package let outputTokens: Int
    package let cacheRead: Int
    package let toolCalls: Int

    package init(text: String, inputTokens: Int, outputTokens: Int, cacheRead: Int, toolCalls: Int) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheRead = cacheRead
        self.toolCalls = toolCalls
    }
}

/// A tool's result: plain text, or content blocks (e.g. an image) for the model.
/// The untyped content shares the transitional wire representation above.
package struct ToolResult {
    package var content: Any          // String or [[String: Any]] blocks
    package var isError: Bool

    package init(content: Any, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    package static func text(_ s: String, isError: Bool = false) -> ToolResult { ToolResult(content: s, isError: isError) }
    package static func blocks(_ b: [[String: Any]]) -> ToolResult { ToolResult(content: b) }
}

package typealias ToolExecutor = (_ name: String, _ input: [String: Any], _ toolset: String?) async -> ToolResult
