import Foundation
import Testing
import FamiliarRuntime
@testable import Familiar

@Suite
struct ConversationBackendTests {
    /// Company gateways often authenticate with their own header, so a gateway alone is enough to connect.
    @Test func aGatewayConnectsWithoutAnAnthropicKey() throws {
        var config = Config()
        config.apiBaseURL = "https://gateway.example.test/anthropic"
        config.apiHeaders = ["Authorization": "Bearer fixture-gateway"]

        let client = try #require(ConversationBackend.make(config: config) as? ClaudeClient)

        #expect(client.baseURL.absoluteString == "https://gateway.example.test/anthropic")
        #expect(!client.serverFallbacks)
    }
}
