import Foundation

/// Both connections provide the same conversation and tool-execution boundary to the app.
protocol ConversationClient: AnyObject {
    var effort: String { get set }
    var maxTokens: Int { get set }
    var maxToolRounds: Int { get set }
    var shouldStop: () -> Bool { get set }

    func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                  executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply
}

enum ConversationBackend {
    static func make(config: Config) -> (any ConversationClient)? {
        if config.connectionMode == "claudeCode" {
            guard ClaudeCodeClient.executable(config: config) != nil else { return nil }
            return ClaudeCodeClient(config: config)
        }
        return config.resolvedApiKey.map { ClaudeClient(config: config, apiKey: $0) }
    }

    static func setupMessage(config: Config) -> String {
        if config.connectionMode == "claudeCode" {
            return "Claude Code was not found. Install it and run claude auth login, then check the connection in Familiar Settings."
        }
        return "Add your API key in Familiar Settings to connect to Claude."
    }
}
