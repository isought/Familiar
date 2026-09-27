import FamiliarContracts
@testable import FamiliarRuntime
import Foundation
import Testing
@testable import Familiar

@Suite
struct ConnectionConfigTests {
    @Test
    func testExistingAPIConfigurationKeepsItsConnectionAndCredentials() throws {
        let existing = Data(#"{"apiKey":"existing-test-key","apiBaseURL":"https://gateway.example.test","apiHeaders":{"X-Workspace":"test"},"model":"existing-api-model","attachScreenshotOnText":false}"#.utf8)

        let config = try JSONDecoder().decode(Config.self, from: existing)

        #expect(config.connectionMode == "api")
        #expect(config.apiKey == "existing-test-key")
        #expect(config.apiBaseURL == "https://gateway.example.test")
        #expect(config.apiHeaders == ["X-Workspace": "test"])
        #expect(config.model == "existing-api-model")
        #expect(config.screenshotMode == "never")
        #expect(config.claudePath == "")
        #expect(config.claudeModel == "")
        #expect(ConversationBackend.make(config: config) is ClaudeClient)
    }

    @Test
    func testCLISettingsRoundTripWithoutReplacingAPISettings() throws {
        var config = Config()
        config.connectionMode = "claudeCode"
        config.claudePath = "/path with spaces/claude"
        config.claudeModel = "sonnet"
        config.apiKey = "saved-test-api-key"
        config.model = "saved-api-model"

        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))

        #expect(restored.connectionMode == "claudeCode")
        #expect(restored.claudePath == config.claudePath)
        #expect(restored.claudeModel == "sonnet")
        #expect(restored.apiKey == "saved-test-api-key")
        #expect(restored.model == "saved-api-model")
    }
}
