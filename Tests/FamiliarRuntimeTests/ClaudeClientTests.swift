import Foundation
import Testing
import FamiliarContracts
@testable import FamiliarRuntime

/// All HTTP traffic is intercepted by a fixture session; no account or service is used.
@Suite
struct ClaudeClientTests {
    @Test
    func toolRoundTripPreservesNamespacesInputsImagesErrorsAndSignedHistory() async throws {
        let thinking: [String: Any] = ["type": "thinking", "thinking": "Inspect the current screen.", "signature": "fixture-signature"]
        let screenInput: [String: Any] = ["display_id": 4, "region": [10, 20, 300, 200]]
        let lookupInput: [String: Any] = ["query": "release notes", "include_archived": false]
        let assistantBlocks: [[String: Any]] = [
            thinking,
            ["type": "tool_use", "id": "screen-call", "name": "screenshot", "toolset_name": "computer", "input": screenInput],
            ["type": "tool_use", "id": "lookup-call", "name": "notes__lookup", "input": lookupInput],
        ]
        let fixture = try HTTPFixture(responses: [
            HTTPFixture.Response(json: ["stop_reason": "tool_use", "content": assistantBlocks,
                                        "usage": ["input_tokens": 10, "output_tokens": 4, "cache_read_input_tokens": 3, "cache_creation_input_tokens": 2]]),
            HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "The lookup failed; the screen is visible."]],
                                        "usage": ["input_tokens": 20, "output_tokens": 6, "cache_read_input_tokens": 8, "cache_creation_input_tokens": 1]]),
        ])
        defer { fixture.close() }
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session)
        let tools: [[String: Any]] = [
            ["type": "computer_toolset_20260801"],
            ["name": "notes__lookup", "description": "Search notes", "input_schema": ["type": "object", "properties": ["query": ["type": "string"]]]],
        ]
        let imageBlocks: [[String: Any]] = [
            ["type": "text", "text": "Current screen"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "ZmFrZS1zY3JlZW5zaG90"]],
        ]
        let initialHistory: [[String: Any]] = [["role": "user", "content": "Read this screen and find the release notes."]]
        var messages = initialHistory
        var calls: [(String, [String: Any], String?)] = []
        let reply = try await client.converse(system: "Help with the current task.", tools: tools, messages: &messages,
                                              executor: { name, input, toolset in
            calls.append((name, input, toolset))
            return toolset == "computer" ? .blocks(imageBlocks) : .text("Notes service unavailable.", isError: true)
        }, onStatus: { _ in })

        #expect(calls.map { $0.0 } == ["screenshot", "notes__lookup"])
        #expect(calls.map { $0.2 } == ["computer", nil])
        let screenCall = try #require(calls.first)
        let lookupCall = try #require(calls.last)
        #expect(NSDictionary(dictionary: screenCall.1).isEqual(to: screenInput))
        #expect(NSDictionary(dictionary: lookupCall.1).isEqual(to: lookupInput))
        let requests = fixture.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let second = try #require(requests.last)
        let sentTools = try #require(first.body["tools"] as? [[String: Any]])
        #expect(NSArray(array: sentTools).isEqual(to: tools))
        let firstHistory = try #require(first.body["messages"] as? [[String: Any]])
        #expect(NSArray(array: firstHistory).isEqual(to: initialHistory))
        let continuedHistory = try #require(second.body["messages"] as? [[String: Any]])
        let expectedResults: [[String: Any]] = [
            ["type": "tool_result", "tool_use_id": "screen-call", "toolset_name": "computer", "content": imageBlocks],
            ["type": "tool_result", "tool_use_id": "lookup-call", "content": "Notes service unavailable.", "is_error": true],
        ]
        let expectedHistory = initialHistory + [
            ["role": "assistant", "content": assistantBlocks],
            ["role": "user", "content": expectedResults],
        ]
        #expect(NSArray(array: continuedHistory).isEqual(to: expectedHistory))
        #expect(NSArray(array: Array(messages.dropLast())).isEqual(to: expectedHistory))
        #expect(messages.last?["role"] as? String == "assistant")
        #expect(reply.text == "The lookup failed; the screen is visible.")
        #expect(reply.inputTokens == 44)
        #expect(reply.outputTokens == 10)
        #expect(reply.cacheRead == 11)
        #expect(reply.toolCalls == 2)
    }

    @Test
    func gatewayHeadersAndModelOptionsRemainSpecificToEachClient() async throws {
        let success = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ready."]]])
        let firstFixture = HTTPFixture(responses: [success, success])
        let secondFixture = HTTPFixture(responses: [success])
        defer { firstFixture.close(); secondFixture.close() }
        let firstClient = ClaudeClient(options: ClaudeAPIOptions(apiKey: "fixture-key-one", model: "fixture-model-one", effort: "low", maxTokens: 321,
                                                                 baseURL: firstFixture.baseURL, headers: ["Authorization": "Bearer fixture-gateway-one", "X-First-Only": "first"]),
                                       session: firstFixture.session)
        let secondClient = ClaudeClient(options: ClaudeAPIOptions(apiKey: "fixture-key-two", model: "fixture-model-two", effort: "high", maxTokens: 654,
                                                                  baseURL: secondFixture.baseURL, headers: ["Authorization": "Bearer fixture-gateway-two", "x-api-key": "fixture-header-override"]),
                                        session: secondFixture.session)
        for client in [firstClient, secondClient, firstClient] {
            var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
            _ = try await client.converse(system: "Fixture system prompt", tools: [], messages: &messages,
                                           executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                           onStatus: { _ in })
        }
        #expect(firstFixture.requests.count == 2)
        #expect(secondFixture.requests.count == 1)
        for captured in firstFixture.requests {
            #expect(captured.request.url?.absoluteString == firstFixture.baseURL + "/v1/messages")
            #expect(captured.request.httpMethod == "POST")
            #expect(captured.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(captured.request.value(forHTTPHeaderField: "x-api-key") == "fixture-key-one")
            #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gateway-one")
            #expect(captured.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(captured.request.value(forHTTPHeaderField: "anthropic-beta") == nil)
            #expect(captured.body["fallbacks"] == nil)
            #expect(captured.body["model"] as? String == "fixture-model-one")
            #expect(captured.body["max_tokens"] as? Int == 321)
            #expect((captured.body["output_config"] as? [String: Any])?["effort"] as? String == "low")
            #expect(captured.body["tools"] == nil)
        }
        let second = try #require(secondFixture.requests.first)
        #expect(second.request.url?.absoluteString == secondFixture.baseURL + "/v1/messages")
        #expect(second.request.value(forHTTPHeaderField: "x-api-key") == "fixture-header-override")
        #expect(second.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gateway-two")
        #expect(second.request.value(forHTTPHeaderField: "X-First-Only") == nil)
        #expect(second.body["model"] as? String == "fixture-model-two")
        #expect(second.body["max_tokens"] as? Int == 654)
        #expect((second.body["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test
    func anthropicsOwnAPIGetsServerSideFallbacks() async throws {
        let success = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ready."]]])
        let fixture = HTTPFixture(responses: [success], host: "api.anthropic.com")
        defer { fixture.close() }
        let client = ClaudeClient(options: options(baseURL: ""), session: fixture.session)
        #expect(client.serverFallbacks)
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        _ = try await client.converse(system: "Fixture system prompt", tools: [], messages: &messages,
                                       executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                       onStatus: { _ in })
        let captured = try #require(fixture.requests.first)
        #expect(captured.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(captured.request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(captured.body["fallbacks"] as? String == "default")
    }

    @Test
    func gatewayWithoutAnAnthropicKeyAuthenticatesThroughItsOwnHeader() async throws {
        let success = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ready."]]])
        let fixture = HTTPFixture(responses: [success])
        defer { fixture.close() }
        let client = ClaudeClient(options: ClaudeAPIOptions(apiKey: "", model: "fixture-model", effort: "medium", maxTokens: 1024,
                                                            baseURL: fixture.baseURL, headers: ["Authorization": "Bearer fixture-gateway"]),
                                  session: fixture.session)
        #expect(!client.serverFallbacks)
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        _ = try await client.converse(system: "Fixture system prompt", tools: [], messages: &messages,
                                       executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                       onStatus: { _ in })
        let captured = try #require(fixture.requests.first)
        #expect(captured.request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gateway")
        #expect(captured.request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(captured.body["fallbacks"] == nil)
    }

    @Test
    func providerHTTPErrorKeepsTheExistingHistoryAndDoesNotExecuteTools() async throws {
        let fixture = try HTTPFixture(responses: [HTTPFixture.Response(json: ["error": ["type": "authentication_error", "message": "Fixture key rejected."]], status: 401)])
        defer { fixture.close() }
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session)
        let original: [[String: Any]] = [["role": "user", "content": "Hello"]]
        var messages = original
        do {
            _ = try await client.converse(system: "Fixture prompt", tools: [], messages: &messages,
                                           executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                           onStatus: { _ in })
            Issue.record("Expected an API error")
        } catch let error as ClaudeError {
            #expect(error.message == "API error 401: Fixture key rejected.")
        }
        #expect(fixture.requests.count == 1)
        #expect(NSArray(array: messages).isEqual(to: original))
    }

    private func options(baseURL: String) -> ClaudeAPIOptions {
        ClaudeAPIOptions(apiKey: "fixture-api-key", model: "fixture-model", effort: "medium", maxTokens: 1024, baseURL: baseURL)
    }
}

private final class HTTPFixture: @unchecked Sendable {
    struct Response {
        let status: Int
        let data: Data

        init(json: [String: Any], status: Int = 200) throws {
            self.status = status
            self.data = try JSONSerialization.data(withJSONObject: json)
        }
    }

    struct CapturedRequest {
        let request: URLRequest
        let body: [String: Any]
    }

    let session: URLSession
    let baseURL: String
    private let host: String
    private let lock = NSLock()
    private var responses: [Response]
    private var captured: [CapturedRequest] = []

    /// A made-up gateway host by default; pass a host to stand in for a real one (requests never leave the process).
    init(responses: [Response], host: String? = nil) {
        self.responses = responses
        if let host {
            self.host = host
            baseURL = "https://\(host)"
        } else {
            self.host = "fixture-\(UUID().uuidString.lowercased()).example.test"
            baseURL = "https://\(self.host)/gateway"
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
        FixtureURLProtocol.registry.register(self, host: self.host)
    }

    var requests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func close() {
        session.invalidateAndCancel()
        FixtureURLProtocol.registry.remove(host: host)
    }

    func response(for request: URLRequest) throws -> Response {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        } else {
            throw URLError(.cannotDecodeRawData)
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        lock.lock()
        defer { lock.unlock() }
        captured.append(CapturedRequest(request: request, body: body))
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private final class FixtureURLProtocol: URLProtocol {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var fixtures: [String: HTTPFixture] = [:]

        func register(_ fixture: HTTPFixture, host: String) {
            lock.lock()
            defer { lock.unlock() }
            fixtures[host] = fixture
        }

        func remove(host: String) {
            lock.lock()
            defer { lock.unlock() }
            fixtures.removeValue(forKey: host)
        }

        func fixture(for host: String) -> HTTPFixture? {
            lock.lock()
            defer { lock.unlock() }
            return fixtures[host]
        }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host, let fixture = Self.registry.fixture(for: host) else {
                throw URLError(.unsupportedURL)
            }
            let fixtureResponse = try fixture.response(for: request)
            guard let response = HTTPURLResponse(url: url, statusCode: fixtureResponse.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixtureResponse.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
