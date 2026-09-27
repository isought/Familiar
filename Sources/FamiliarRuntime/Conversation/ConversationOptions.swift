import Foundation

/// Only the settings needed for one direct API connection. Credential lookup stays
/// at the application boundary; the runtime receives the resolved value.
package struct ClaudeAPIOptions {
    package let apiKey: String
    package let model: String
    package let effort: String
    package let maxTokens: Int
    package let baseURL: String
    package let headers: [String: String]

    package init(apiKey: String, model: String, effort: String, maxTokens: Int,
                 baseURL: String = "", headers: [String: String] = [:]) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.baseURL = baseURL
        self.headers = headers
    }
}

/// CLI settings deliberately exclude API credentials and gateway configuration.
package struct ClaudeCodeOptions {
    package let executablePath: String
    package let model: String
    package let effort: String
    package let maxTokens: Int

    package init(executablePath: String = "", model: String = "", effort: String, maxTokens: Int) {
        self.executablePath = executablePath
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
    }
}
