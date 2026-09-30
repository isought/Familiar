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

    // MARK: network failures (the bug: a fresh install showed only "The network connection was lost.")

    @Test
    func aDroppedConnectionIsRetriedAndTheQuestionStillGetsAnswered() async throws {
        let success = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ready."]]])
        let fixture = HTTPFixture(responses: [HTTPFixture.Response(failure: URLError(.networkConnectionLost)), success])
        defer { fixture.close() }
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session)
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]

        let reply = try await client.converse(system: "Fixture prompt", tools: [], messages: &messages,
                                              executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                              onStatus: { _ in })

        #expect(reply.text == "Ready.")
        #expect(fixture.requests.count == 2)
    }

    @Test
    func aConnectionThatKeepsDroppingSaysWhereWhatAndWhatToTry() async throws {
        let lost = HTTPFixture.Response(failure: URLError(.networkConnectionLost))
        let fixture = HTTPFixture(responses: [lost, lost, lost])
        defer { fixture.close() }
        let host = try #require(URL(string: fixture.baseURL)?.host)
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session)
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]

        do {
            _ = try await client.converse(system: "Fixture prompt", tools: [], messages: &messages,
                                           executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                           onStatus: { _ in })
            Issue.record("Expected a connection error")
        } catch let error as ClaudeError {
            #expect(error.message.contains(host))
            #expect(error.message.contains("dropped"))
            #expect(error.message.contains("tried 3 times"))
            #expect(error.message.contains("Check your connection"))
        }
        #expect(fixture.requests.count == 3)
    }

    @Test
    func aBusyServerIsRetriedThenAnswers() async throws {
        let busy = try HTTPFixture.Response(json: ["error": ["type": "overloaded_error", "message": "Overloaded"]], status: 529)
        let success = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ready."]]])
        let fixture = HTTPFixture(responses: [busy, success])
        defer { fixture.close() }
        let reply = try await ask(fixture)
        #expect(reply.text == "Ready.")
        #expect(fixture.requests.count == 2)
    }

    @Test
    func aRateLimitHonorsRetryAfter() async throws {
        let limited = try HTTPFixture.Response(json: ["error": ["type": "rate_limit_error", "message": "Slow down"]], status: 429, headers: ["retry-after": "0"])
        let success = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ready."]]])
        let fixture = HTTPFixture(responses: [limited, success])
        defer { fixture.close() }
        #expect(try await ask(fixture).text == "Ready.")
        #expect(fixture.requests.count == 2)
        #expect(ClaudeClient.retryAfter("2") == 2)
        #expect(ClaudeClient.retryAfter(" 0.5 ") == 0.5)
        #expect(ClaudeClient.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(ClaudeClient.retryAfter("-1") == nil)
        #expect(ClaudeClient.retryAfter(nil) == nil)
    }

    @Test
    func aServerThatStaysDownSaysHowManyTimesItTried() async throws {
        let down = try HTTPFixture.Response(json: ["error": ["type": "api_error", "message": "Service unavailable"]], status: 503)
        let fixture = HTTPFixture(responses: [down, down, down])
        defer { fixture.close() }
        do { _ = try await ask(fixture); Issue.record("Expected an API error") }
        catch let error as ClaudeError { #expect(error.message == "API error 503: Service unavailable (tried 3 times)") }
        #expect(fixture.requests.count == 3)
    }

    @Test
    func beingOfflineIsNotRetriedAndSaysSo() async throws {
        let fixture = HTTPFixture(responses: [HTTPFixture.Response(failure: URLError(.notConnectedToInternet))])
        defer { fixture.close() }
        let host = try #require(URL(string: fixture.baseURL)?.host)
        do { _ = try await ask(fixture); Issue.record("Expected an offline error") }
        catch let error as ClaudeError {
            #expect(error.message.contains("offline"))
            #expect(error.message.contains(host))
        }
        #expect(fixture.requests.count == 1)
    }

    @Test
    func aTimeoutIsNotRetriedAndSaysHowLongItWaited() async throws {
        let fixture = HTTPFixture(responses: [HTTPFixture.Response(failure: URLError(.timedOut))])
        defer { fixture.close() }
        do { _ = try await ask(fixture); Issue.record("Expected a timeout error") }
        catch let error as ClaudeError { #expect(error.message.contains("didn't answer within")) }
        #expect(fixture.requests.count == 1)
    }

    @Test
    func aStoppedRequestStaysAStop() async throws {
        let fixture = HTTPFixture(responses: [HTTPFixture.Response(failure: URLError(.cancelled))])
        defer { fixture.close() }
        do { _ = try await ask(fixture); Issue.record("Expected cancellation") }
        catch let error as URLError { #expect(error.code == .cancelled) }
        #expect(fixture.requests.count == 1)
    }

    @Test
    func certificateFailuresPointAtAProxy() {
        let message = ClaudeClient.explain(URLError(.serverCertificateUntrusted), host: "api.anthropic.com", elapsed: 0.2, attempts: 1, timeout: 240)
        #expect(message.contains("api.anthropic.com"))
        #expect(message.contains("proxy"))
    }

    @Test
    func failedAttemptsAreLoggedWithCodeHostAndAttempt() async throws {
        let success = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ready."]]])
        let fixture = HTTPFixture(responses: [HTTPFixture.Response(failure: URLError(.networkConnectionLost)), success])
        defer { fixture.close() }
        let host = try #require(URL(string: fixture.baseURL)?.host)
        let lines = LogLines()
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session, logger: { lines.append($0) })
        client.retryDelays = [0, 0]
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        _ = try await client.converse(system: "Fixture prompt", tools: [], messages: &messages,
                                       executor: { _, _, _ in .text("unexpected") }, onStatus: { _ in })
        #expect(lines.all.contains { $0.contains("URLError -1005") && $0.contains(host) && $0.contains("attempt 1") })
    }

    @Test
    func toolErrorsAreLoggedNotJustTheCalls() async throws {
        let toolUse = try HTTPFixture.Response(json: ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "call-1", "name": "lookup", "input": ["q": "status"]]]])
        let done = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Done."]]])
        let fixture = HTTPFixture(responses: [toolUse, done])
        defer { fixture.close() }
        let lines = LogLines()
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session, logger: { lines.append($0) })
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        _ = try await client.converse(system: "Fixture prompt", tools: [["name": "lookup"]], messages: &messages,
                                       executor: { _, _, _ in .text("Lookup service is down.", isError: true) }, onStatus: { _ in })
        #expect(lines.all.contains("tool error: lookup: Lookup service is down."))
    }

    @Test
    func aReplyCutOffInsideAToolCallIsAskedAgainWithMoreRoom() async throws {
        let cut = try HTTPFixture.Response(json: ["stop_reason": "max_tokens", "usage": ["input_tokens": 10, "output_tokens": 1024],
            "content": [["type": "text", "text": "Submitting."], ["type": "tool_use", "id": "cut-call", "name": "submit_reading_collection", "input": [:]]]])
        let whole = try HTTPFixture.Response(json: ["stop_reason": "tool_use", "usage": ["input_tokens": 10, "output_tokens": 1500],
            "content": [["type": "tool_use", "id": "whole-call", "name": "submit_reading_collection", "input": ["items": 25]]]])
        let done = try HTTPFixture.Response(json: ["stop_reason": "end_turn", "usage": ["input_tokens": 20, "output_tokens": 3],
            "content": [["type": "text", "text": "Saved."]]])
        let fixture = HTTPFixture(responses: [cut, whole, done])
        defer { fixture.close() }
        let lines = LogLines(), calls = LogLines()
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session, logger: { lines.append($0) })
        var messages: [[String: Any]] = [["role": "user", "content": "Read the inbox."]]
        let reply = try await client.converse(system: "Fixture prompt", tools: [["name": "submit_reading_collection"]], messages: &messages,
                                              executor: { name, _, _ in calls.append(name); return .text("Saved locally.") }, onStatus: { _ in })

        #expect(reply.text == "Saved.")
        #expect(calls.all == ["submit_reading_collection"])                // the cut-off call never ran
        #expect(fixture.requests.map { $0.body["max_tokens"] as? Int } == [1024, 2048, 2048])
        #expect(!String(describing: messages).contains("cut-call"))
        #expect(reply.outputTokens == 1024 + 1500 + 3)                     // the cut-off attempt is still counted
        #expect(lines.all.contains("reply cut off inside a tool call at 1024 tokens; asking again with 2048"))
    }

    @Test
    func aReplyStillCutOffAtTheCeilingComesBackWithoutItsUnfinishedCall() async throws {
        let cut = try HTTPFixture.Response(json: ["stop_reason": "max_tokens",
            "content": [["type": "tool_use", "id": "cut-call", "name": "submit_reading_collection", "input": [:]]]])
        let fixture = HTTPFixture(responses: [cut, cut])
        defer { fixture.close() }
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session)
        client.maxTokens = 16_000
        var messages: [[String: Any]] = [["role": "user", "content": "Read the inbox."]]
        let reply = try await client.converse(system: "Fixture prompt", tools: [["name": "submit_reading_collection"]], messages: &messages,
                                              executor: { _, _, _ in Issue.record("An unfinished call must not run"); return .text("unexpected") },
                                              onStatus: { _ in })

        #expect(fixture.requests.map { $0.body["max_tokens"] as? Int } == [16_000, 32_000])
        #expect(reply.text.hasSuffix(ClaudeClient.cutOffNote))
        #expect(!String(describing: messages).contains("cut-call"))       // the history stays valid for the next turn
    }

    private func ask(_ fixture: HTTPFixture) async throws -> ClaudeReply {
        let client = ClaudeClient(options: options(baseURL: fixture.baseURL), session: fixture.session)
        client.retryDelays = [0, 0]
        var messages: [[String: Any]] = [["role": "user", "content": "Hello"]]
        return try await client.converse(system: "Fixture prompt", tools: [], messages: &messages,
                                         executor: { _, _, _ in Issue.record("Unexpected tool call"); return .text("unexpected") },
                                         onStatus: { _ in })
    }

    private func options(baseURL: String) -> ClaudeAPIOptions {
        ClaudeAPIOptions(apiKey: "fixture-api-key", model: "fixture-model", effort: "medium", maxTokens: 1024, baseURL: baseURL)
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

private final class HTTPFixture: @unchecked Sendable {
    struct Response {
        let status: Int
        let data: Data
        var headers: [String: String] = [:]
        /// The connection fails instead of answering, e.g. URLError(.networkConnectionLost).
        var failure: URLError?

        init(json: [String: Any], status: Int = 200, headers: [String: String] = [:]) throws {
            self.status = status
            self.data = try JSONSerialization.data(withJSONObject: json)
            self.headers = headers
        }

        init(failure: URLError) {
            status = 0
            data = Data()
            self.failure = failure
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
            if let failure = fixtureResponse.failure { throw failure }
            let headers = fixtureResponse.headers.merging(["Content-Type": "application/json"]) { given, _ in given }
            guard let response = HTTPURLResponse(url: url, statusCode: fixtureResponse.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
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
