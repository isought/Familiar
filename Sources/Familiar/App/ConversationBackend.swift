import Foundation
import FamiliarContracts
import FamiliarRuntime

/// The application resolves configuration, credentials, logging, and bundle paths
/// before selecting a provider. Runtime providers do not depend on app services.
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

extension ClaudeClient {
    convenience init(config: Config, apiKey: String) {
        self.init(options: ClaudeAPIOptions(apiKey: apiKey, model: config.model, effort: config.effort,
                                           maxTokens: config.maxTokens, baseURL: config.apiBaseURL,
                                           headers: config.apiHeaders), logger: { Log.info($0) })
    }
}

extension ClaudeCodeClient {
    convenience init(config: Config) {
        self.init(options: ClaudeCodeOptions(executablePath: config.claudePath, model: config.claudeModel,
                                            effort: config.effort, maxTokens: config.maxTokens),
                  pythonRuntime: PythonRuntime(config: config))
    }

    static func executable(config: Config) -> String? {
        executable(path: config.claudePath)
    }

    static func authenticationStatus(config: Config) async -> String {
        await authenticationStatus(path: config.claudePath)
    }
}

extension PythonRuntime {
    init(config: Config) {
        self = .discover(uvPath: config.uvPath, resourceURL: Bundle.main.resourceURL,
                         workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }
}
